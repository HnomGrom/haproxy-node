import {
  BadRequestException,
  Injectable,
  Logger,
  OnModuleInit,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { exec } from 'child_process';
import { writeFile, unlink, rename } from 'fs/promises';
import { promisify } from 'util';
import { isIPv6 } from 'net';
import { Mutex } from 'async-mutex';
import { PrismaService } from '../prisma/prisma.service';
import {
  IP_OR_CIDR_REGEX,
  IP_OR_CIDR_V6_REGEX,
} from './dto/lockdown.dto';

const execAsync = promisify(exec);

// `-w 5` заставляет iptables/ip6tables ждать xtables.lock до 5 секунд
// (по умолчанию exit 4 сразу). Без флага конкуренция с fail2ban / docker /
// netfilter-persistent даёт race и lockdown «не включается на занятых нодах».
const IPT_WAIT = '-w 5';

type Family = 'v4' | 'v6';

@Injectable()
export class LockdownService implements OnModuleInit {
  private readonly logger = new Logger(LockdownService.name);

  // ipset ограничивает имя set'а в 31 символ (IPSET_MAXNAMELEN).
  // Префикс 11 + счётчик до 20 цифр = в пределах лимита.
  private readonly SET_V4 = 'vless_lockdown';
  private readonly SET_V6 = 'vless_lockdown6';
  private readonly TMP_SET_PREFIX = 'vl_lkd_tmp_';
  private readonly MAX_ELEM = 1_000_000;
  private readonly HASH_SIZE = 65536;
  private readonly PORT_MIN: number;
  private readonly PORT_MAX: number;
  private readonly MAX_REMOVE_ITERATIONS = 100;
  private tmpCounter = 0;
  // IPv6 поддержка детектится один раз при старте — если ip6tables нет
  // или INPUT-цепочка недоступна, v6-операции пропускаются (но ip-листы
  // v6-семьи всё равно валидируются, просто никуда не пишутся).
  private ipv6Enabled = false;

  // Сериализует все мутирующие операции (enable/disable/addIps/removeIps).
  // Без mutex два параллельных enable() читают `iptables -C`, оба видят
  // «правила нет», оба делают `iptables -I` — получаем дубликат match-set.
  // Также защищает atomic-swap в bulkLoadIps от потери записей из
  // одновременного addIps.
  private readonly mutex = new Mutex();

  constructor(
    private readonly config: ConfigService,
    private readonly prisma: PrismaService,
  ) {
    this.PORT_MIN = Number(this.config.get('FRONTEND_PORT_MIN', 10000));
    this.PORT_MAX = Number(this.config.get('FRONTEND_PORT_MAX', 65000));
  }

  async onModuleInit(): Promise<void> {
    this.ipv6Enabled = await this.detectIpv6();
    this.logger.log(
      `IPv6 lockdown: ${this.ipv6Enabled ? 'enabled' : 'disabled (ip6tables INPUT недоступен)'}`,
    );
    // Чистим осиротевшие tmp-set'ы от прошлого процесса (после SIGKILL
    // во время bulkLoadIps tmp-set остаётся — здесь убираем).
    await this.cleanupStaleTmpSets();
    // Гарантируем существование ipset — чтобы incremental-add'ы работали
    // даже когда lockdown не активирован (subscription-api накапливает IP).
    await this.ensureIpset('v4');
    if (this.ipv6Enabled) {
      await this.ensureIpset('v6');
    }
  }

  // ═══════════════════════════════════════════════════════════
  //  PUBLIC: IPSET content management
  // ═══════════════════════════════════════════════════════════

  async addIps(ips: string[]): Promise<{
    requested: number;
    added: number;
    skipped: number;
    invalid: number;
    duplicates: number;
  }> {
    return this.mutex.runExclusive(async () => {
      const { v4, v6, invalid, duplicates } = this.dedupeAndValidate(ips);

      // Если после dedupe не осталось записей — early return без mutate'а
      // ipset/persist/event-log. Иначе шум в audit-логе при no-op вызовах.
      if (v4.length === 0 && v6.length === 0) {
        return {
          requested: ips.length,
          added: 0,
          skipped: ips.length,
          invalid,
          duplicates,
        };
      }

      await this.ensureIpset('v4');
      if (this.ipv6Enabled) await this.ensureIpset('v6');

      let added = 0;

      if (v4.length > 0) {
        const before = await this.whitelistSize('v4');
        await this.applyIpsetAdds(v4, 'v4');
        const after = await this.whitelistSize('v4');
        added += Math.max(0, after - before);
      }

      if (v6.length > 0 && this.ipv6Enabled) {
        const before = await this.whitelistSize('v6');
        await this.applyIpsetAdds(v6, 'v6');
        const after = await this.whitelistSize('v6');
        added += Math.max(0, after - before);
      } else if (v6.length > 0 && !this.ipv6Enabled) {
        this.logger.warn(
          `Получено ${v6.length} IPv6 записей, но IPv6 lockdown не активен — записи проигнорированы`,
        );
      }

      const skipped = ips.length - added;

      await this.persist();
      await this.prisma.lockdownEvent.create({
        data: { action: 'add', source: 'api', reason: null, ipCount: added },
      });

      this.logger.log(
        `Added ${added} IPs/CIDRs (requested ${ips.length}, invalid ${invalid}, duplicates ${duplicates})`,
      );
      return {
        requested: ips.length,
        added,
        skipped,
        invalid,
        duplicates,
      };
    });
  }

  async removeIps(ips: string[]): Promise<{
    requested: number;
    removed: number;
    invalid: number;
    duplicates: number;
  }> {
    return this.mutex.runExclusive(async () => {
      const { v4, v6, invalid, duplicates } = this.dedupeAndValidate(ips);

      if (v4.length === 0 && v6.length === 0) {
        return { requested: ips.length, removed: 0, invalid, duplicates };
      }

      await this.ensureIpset('v4');
      if (this.ipv6Enabled) await this.ensureIpset('v6');

      let removed = 0;

      if (v4.length > 0) {
        const before = await this.whitelistSize('v4');
        await this.batchIpsetOperation(v4, 'del', 'v4');
        const after = await this.whitelistSize('v4');
        removed += Math.max(0, before - after);
      }

      if (v6.length > 0 && this.ipv6Enabled) {
        const before = await this.whitelistSize('v6');
        await this.batchIpsetOperation(v6, 'del', 'v6');
        const after = await this.whitelistSize('v6');
        removed += Math.max(0, before - after);
      }

      await this.persist();
      await this.prisma.lockdownEvent.create({
        data: {
          action: 'remove',
          source: 'api',
          reason: null,
          ipCount: removed,
        },
      });

      this.logger.log(
        `Removed ${removed} IPs/CIDRs (requested ${ips.length})`,
      );
      return { requested: ips.length, removed, invalid, duplicates };
    });
  }

  async listIps(limit = 1000): Promise<string[]> {
    await this.ensureIpset('v4');
    const v4 = await this.listSet(this.SET_V4, limit);
    if (!this.ipv6Enabled) return v4;
    const remaining = Math.max(0, limit - v4.length);
    if (remaining === 0) return v4;
    await this.ensureIpset('v6');
    const v6 = await this.listSet(this.SET_V6, remaining);
    return v4.concat(v6);
  }

  // ═══════════════════════════════════════════════════════════
  //  PUBLIC: lockdown toggle
  // ═══════════════════════════════════════════════════════════

  async enable(
    ips: string[],
    reason?: string,
  ): Promise<{
    enabled: boolean;
    whitelistSize: number;
    whitelistSizeV6: number;
    ipv6Enabled: boolean;
    diagnostics: {
      v4Rule: boolean;
      v6Rule: boolean;
      v4SetSize: number;
      v6SetSize: number;
    };
  }> {
    return this.mutex.runExclusive(async () => {
      // Валидация ДО pre-event'а — иначе trivially invalid input
      // (`["dead"]` проходит shape-regex но isIPv6 fails) пишет 2 события
      // (attempt + failed) вместо одного 400 без записей.
      const { v4, v6, invalid } = this.dedupeAndValidate(ips);
      const total = v4.length + v6.length;

      if (total === 0) {
        throw new BadRequestException(
          'Empty or all-invalid ips[] — refusing to activate lockdown (would block all clients)',
        );
      }

      // Pre-event: пишем «attempting» ДО мутаций iptables/ipset. Если процесс
      // упадёт — lastEvent не «врёт» что lockdown успешен. На успехе/ошибке
      // финализируем отдельной записью.
      const pending = await this.prisma.lockdownEvent.create({
        data: {
          action: 'enable_attempt',
          source: 'api',
          reason: reason ?? null,
          ipCount: 0,
        },
      });

      try {

        // ВАЖНО: трогаем ТОЛЬКО семейство, для которого пользователь
        // прислал IP. Если v4=[], не делаем bulkLoad+rule для v4 — иначе
        // vless_lockdown будет затёрт пустым set'ом и весь v4 трафик
        // дропнется. Симметрично для v6. enable() — это «активировать
        // lockdown для семейств, IP которых ниже», а не «затереть всё».
        const applyV4 = v4.length > 0;
        const applyV6 = v6.length > 0 && this.ipv6Enabled;

        if (v6.length > 0 && !this.ipv6Enabled) {
          this.logger.warn(
            `Получено ${v6.length} IPv6 записей, но IPv6 lockdown не активен — записи проигнорированы`,
          );
        }

        this.logger.log(
          `Activating lockdown: v4=${v4.length}${applyV4 ? '' : ' (skip)'} v6=${v6.length}${applyV6 ? '' : ' (skip)'} invalid=${invalid} (reason: ${reason ?? 'n/a'})`,
        );

        if (applyV4) {
          await this.bulkLoadIps(v4, 'v4');
          await this.ensureIptablesRule('v4');
        }

        if (applyV6) {
          await this.bulkLoadIps(v6, 'v6');
          await this.ensureIptablesRule('v6');
        }

        await this.persist();

        // Self-check проверяет ТОЛЬКО те семейства, что мы реально применили.
        // Раньше при v4-only input на dual-stack хосте self-check ожидал
        // v6Rule и фейлил (хотя v6 мы намеренно не трогали).
        const diagnostics = await this.selfCheck();
        const v4OK = !applyV4 || diagnostics.v4Rule;
        const v6OK = !applyV6 || diagnostics.v6Rule;
        if (!v4OK || !v6OK) {
          this.logger.error(
            `Self-check FAILED after enable: ${JSON.stringify({ ...diagnostics, applyV4, applyV6 })}`,
          );
          throw new Error('Lockdown self-check failed — match-set rule missing after apply');
        }

        await this.prisma.lockdownEvent.create({
          data: {
            action: 'enable',
            source: 'api',
            reason: reason ?? null,
            ipCount: total,
          },
        });

        this.logger.log(
          `Lockdown ENABLED (v4=${diagnostics.v4SetSize} v6=${diagnostics.v6SetSize})`,
        );
        return {
          enabled: true,
          whitelistSize: diagnostics.v4SetSize,
          whitelistSizeV6: diagnostics.v6SetSize,
          ipv6Enabled: this.ipv6Enabled,
          diagnostics,
        };
      } catch (err) {
        await this.prisma.lockdownEvent.create({
          data: {
            action: 'enable_failed',
            source: 'api',
            reason: `[pending=${pending.id}] ${reason ?? ''} :: ${(err as Error).message}`.slice(0, 256),
            ipCount: 0,
          },
        });
        throw err;
      }
    });
  }

  async disable(reason?: string): Promise<{ enabled: boolean }> {
    return this.mutex.runExclusive(async () => {
      // Если lockdown уже выключен — no-op без шума в audit-логе. Иначе
      // событие 'disable' пишется на каждый /lockdown/off, и оператор не
      // может по lastEvent сказать "только что был disable" vs "просто
      // подёргали кнопку".
      const v4Active = await this.isEnabled('v4');
      const v6Active = this.ipv6Enabled ? await this.isEnabled('v6') : false;
      if (!v4Active && !v6Active) {
        this.logger.log('Lockdown disable: уже выключен — no-op');
        return { enabled: false };
      }

      const pending = await this.prisma.lockdownEvent.create({
        data: {
          action: 'disable_attempt',
          source: 'api',
          reason: reason ?? null,
          ipCount: 0,
        },
      });

      try {
        if (v4Active) {
          await this.ensureFallbackAcceptRule('v4');
          await this.removeIptablesRule('v4');
        }
        if (v6Active) {
          await this.ensureFallbackAcceptRule('v6');
          await this.removeIptablesRule('v6');
        }
        await this.persist();

        await this.prisma.lockdownEvent.create({
          data: {
            action: 'disable',
            source: 'api',
            reason: reason ?? null,
            ipCount: 0,
          },
        });

        this.logger.log('Lockdown DISABLED');
        return { enabled: false };
      } catch (err) {
        await this.prisma.lockdownEvent.create({
          data: {
            action: 'disable_failed',
            source: 'api',
            reason: `[pending=${pending.id}] ${reason ?? ''} :: ${(err as Error).message}`.slice(0, 256),
            ipCount: 0,
          },
        });
        throw err;
      }
    });
  }

  async status() {
    const [v4Enabled, v6Enabled, v4Size, v6Size, lastEvent] = await Promise.all([
      this.isEnabled('v4'),
      this.ipv6Enabled ? this.isEnabled('v6') : Promise.resolve(false),
      this.whitelistSize('v4'),
      this.ipv6Enabled ? this.whitelistSize('v6') : Promise.resolve(0),
      this.prisma.lockdownEvent.findFirst({ orderBy: { createdAt: 'desc' } }),
    ]);
    return {
      enabled: v4Enabled || v6Enabled,
      enabledV4: v4Enabled,
      enabledV6: v6Enabled,
      ipv6Enabled: this.ipv6Enabled,
      whitelistSize: v4Size,
      whitelistSizeV6: v6Size,
      lastEvent,
    };
  }

  async isEnabled(family: Family = 'v4'): Promise<boolean> {
    const ipt = this.iptablesBin(family);
    const set = this.setName(family);
    try {
      await execAsync(
        `${ipt} ${IPT_WAIT} -C INPUT -p tcp -m multiport ` +
          `--dports ${this.PORT_MIN}:${this.PORT_MAX} ` +
          `-m set --match-set ${set} src -j ACCEPT 2>/dev/null`,
      );
      return true;
    } catch {
      return false;
    }
  }

  async whitelistSize(family: Family = 'v4'): Promise<number> {
    const set = this.setName(family);
    try {
      // -t (terse) не дампит все entries — O(1) даже для 1M записей.
      const { stdout } = await execAsync(
        `ipset list -t ${set} 2>/dev/null | awk -F': ' '/Number of entries/ {print $2}'`,
      );
      const n = parseInt(stdout.trim(), 10);
      // Defensive: ipset не возвращает отрицательные, но `parseInt('-1') = -1`.
      // Без clamp — отрицательный результат прокинется в diagnostics клиенту.
      return Number.isFinite(n) && n > 0 ? n : 0;
    } catch {
      return 0;
    }
  }

  // ═══════════════════════════════════════════════════════════
  //  PRIVATE
  // ═══════════════════════════════════════════════════════════

  private iptablesBin(family: Family): string {
    return family === 'v4' ? 'iptables' : 'ip6tables';
  }

  private setName(family: Family): string {
    return family === 'v4' ? this.SET_V4 : this.SET_V6;
  }

  private setArgs(family: Family): string {
    // hash:net поддерживает и точные IP, и CIDR-диапазоны. Lookup O(1).
    const inet = family === 'v4' ? 'inet' : 'inet6';
    return `hash:net maxelem ${this.MAX_ELEM} hashsize ${this.HASH_SIZE} family ${inet}`;
  }

  private async detectIpv6(): Promise<boolean> {
    try {
      await execAsync(`ip6tables ${IPT_WAIT} -S INPUT 2>/dev/null`);
      return true;
    } catch {
      return false;
    }
  }

  private async cleanupStaleTmpSets(): Promise<void> {
    try {
      const { stdout } = await execAsync(
        `ipset list -n 2>/dev/null | grep '^${this.TMP_SET_PREFIX}' || true`,
      );
      const stale = stdout
        .split('\n')
        .map((s) => s.trim())
        .filter(Boolean);
      for (const name of stale) {
        await execAsync(`ipset destroy ${name}`).catch(() => {});
      }
      if (stale.length > 0) {
        this.logger.log(
          `Cleaned up ${stale.length} stale tmp ipset(s) from prior process`,
        );
      }
    } catch {
      // ipset недоступен на boot'е — не валим старт сервиса
    }
  }

  /**
   * Идемпотентно гарантирует существование ipset нужного типа и family.
   * Если set уже существует с НЕправильным типом (например hash:ip от
   * старой версии), пересоздаёт. -exist сам по себе wrong-type не лечит.
   */
  private async ensureIpset(family: Family): Promise<void> {
    const set = this.setName(family);
    const expectedType = 'hash:net';
    let actualType: string | null = null;
    try {
      const { stdout } = await execAsync(
        `ipset list -t ${set} 2>/dev/null | awk -F': ' '/^Type/ {print $2; exit}'`,
      );
      actualType = stdout.trim() || null;
    } catch {
      actualType = null;
    }

    if (actualType && actualType !== expectedType) {
      this.logger.warn(
        `ipset ${set} существует с типом '${actualType}' (ожидается ${expectedType}) — пересоздаю`,
      );
      // Снять iptables-правило, ссылающееся на set (иначе destroy упадёт "in use")
      const ipt = this.iptablesBin(family);
      await execAsync(
        `${ipt} ${IPT_WAIT} -D INPUT -p tcp -m multiport ` +
          `--dports ${this.PORT_MIN}:${this.PORT_MAX} ` +
          `-m set --match-set ${set} src -j ACCEPT 2>/dev/null || true`,
      );
      await execAsync(`ipset destroy ${set}`).catch(() => {});
      await execAsync(`ipset create ${set} ${this.setArgs(family)}`);
      return;
    }

    await execAsync(`ipset create ${set} ${this.setArgs(family)} -exist`);
  }

  private newTmpSetName(): string {
    // Монотонный счётчик защищает от коллизии при параллельных
    // вызовах внутри процесса. Stale tmp-set'ы от прошлого run'а
    // чистятся в onModuleInit (cleanupStaleTmpSets).
    // ВАЖНО: ipset лимит — 31 символ на имя (IPSET_MAXNAMELEN).
    return `${this.TMP_SET_PREFIX}${++this.tmpCounter}`;
  }

  /**
   * Atomic bulk replace содержимого ipset через restore+swap.
   * 100k записей за 1-3 сек. Содержимое меняется атомарно.
   */
  private async bulkLoadIps(ips: string[], family: Family): Promise<void> {
    await this.ensureIpset(family);
    const set = this.setName(family);
    const tmpSet = this.newTmpSetName();
    const tmpFile = `/tmp/ipset-lockdown-${family}-${process.pid}-${Date.now()}.txt`;

    // tmp-set с ТЕМИ ЖЕ параметрами — иначе swap упадёт на type mismatch.
    await execAsync(`ipset create ${tmpSet} ${this.setArgs(family)} -exist`);
    await execAsync(`ipset flush ${tmpSet}`);

    const lines = ips.map((ip) => `add ${tmpSet} ${ip}`).join('\n') + '\n';
    await writeFile(tmpFile, lines, 'utf-8');

    try {
      // -f (НЕ -file!) — короткий флаг для input-файла.
      // -! подавляет "already added" ошибки на уровне каждой add-строки.
      await execAsync(`ipset restore -! -f ${tmpFile}`, {
        maxBuffer: 100 * 1024 * 1024,
      });
      await execAsync(`ipset swap ${set} ${tmpSet}`);
      await execAsync(`ipset destroy ${tmpSet}`);
    } catch (err) {
      await execAsync(`ipset destroy ${tmpSet}`).catch(() => {});
      throw err;
    } finally {
      await unlink(tmpFile).catch(() => {});
    }
  }

  private async applyIpsetAdds(ips: string[], family: Family): Promise<void> {
    const set = this.setName(family);
    if (ips.length <= 10) {
      // Для маленьких списков — прямой ipset add (нет оверхеда на tmp-файл).
      // -exist подавляет ошибку "already added".
      for (const ip of ips) {
        await execAsync(`ipset add ${set} ${ip} -exist`).catch((err) =>
          this.logger.warn(
            `ipset add ${set} ${ip} failed: ${(err as Error).message}`,
          ),
        );
      }
    } else {
      await this.batchIpsetOperation(ips, 'add', family);
    }
  }

  private async batchIpsetOperation(
    ips: string[],
    op: 'add' | 'del',
    family: Family,
  ): Promise<void> {
    const set = this.setName(family);
    const tmpFile = `/tmp/ipset-${op}-${family}-${process.pid}-${Date.now()}.txt`;
    const lines = ips.map((ip) => `${op} ${set} ${ip}`).join('\n') + '\n';
    await writeFile(tmpFile, lines, 'utf-8');

    try {
      await execAsync(`ipset restore -! -f ${tmpFile}`, {
        maxBuffer: 100 * 1024 * 1024,
      });
    } finally {
      await unlink(tmpFile).catch(() => {});
    }
  }

  /**
   * Активировать match-set правило для семейства family.
   * INSERT нового правила ДО DELETE общего ACCEPT — без окна без ACCEPT.
   */
  private async ensureIptablesRule(family: Family): Promise<void> {
    const ipt = this.iptablesBin(family);
    const set = this.setName(family);
    try {
      await execAsync(
        `${ipt} ${IPT_WAIT} -C INPUT -p tcp -m multiport ` +
          `--dports ${this.PORT_MIN}:${this.PORT_MAX} ` +
          `-m set --match-set ${set} src -j ACCEPT 2>/dev/null`,
      );
    } catch {
      await execAsync(
        `${ipt} ${IPT_WAIT} -I INPUT 1 -p tcp -m multiport ` +
          `--dports ${this.PORT_MIN}:${this.PORT_MAX} ` +
          `-m set --match-set ${set} src -j ACCEPT`,
      );
    }
    // Общий ACCEPT убираем ПОСЛЕ установки match-set правила.
    await execAsync(
      `${ipt} ${IPT_WAIT} -D INPUT -p tcp -m multiport ` +
        `--dports ${this.PORT_MIN}:${this.PORT_MAX} -j ACCEPT 2>/dev/null || true`,
    );
  }

  private async removeIptablesRule(family: Family): Promise<void> {
    const ipt = this.iptablesBin(family);
    const set = this.setName(family);
    // Чистим все дубликаты match-set правила (если случились). Лимит итераций
    // защищает от бесконечного цикла на mock-iptables / kernel-баге.
    let i = 0;
    for (; i < this.MAX_REMOVE_ITERATIONS; i++) {
      try {
        // Сначала проверяем, что правило вообще существует — это позволяет
        // отличить "правила нет" (норма для disable() без enable()) от
        // других ошибок (xtables-lock, OOM). 2>/dev/null убирает предсказуемый
        // stderr "iptables: Bad rule" при отсутствии правила.
        await execAsync(
          `${ipt} ${IPT_WAIT} -C INPUT -p tcp -m multiport ` +
            `--dports ${this.PORT_MIN}:${this.PORT_MAX} ` +
            `-m set --match-set ${set} src -j ACCEPT 2>/dev/null`,
        );
      } catch {
        // Правила нет — закончили чистить дубликаты.
        if (i > 10) {
          this.logger.warn(
            `removeIptablesRule(${family}): удалено ${i} правил — необычно много`,
          );
        }
        return;
      }

      try {
        await execAsync(
          `${ipt} ${IPT_WAIT} -D INPUT -p tcp -m multiport ` +
            `--dports ${this.PORT_MIN}:${this.PORT_MAX} ` +
            `-m set --match-set ${set} src -j ACCEPT`,
        );
      } catch (err) {
        // Правило ЕСТЬ, но удалить не вышло — реальная ошибка (xtables locked,
        // ENOMEM). Не молчим — иначе disable() рапортует success, а правило
        // продолжает работать.
        throw new Error(
          `iptables -D failed (family=${family}): ${(err as Error).message}`,
        );
      }
    }
    this.logger.error(
      `removeIptablesRule(${family}): достигнут лимит ${this.MAX_REMOVE_ITERATIONS} итераций — возможен баг ядра, прекращаю`,
    );
  }

  private async ensureFallbackAcceptRule(family: Family): Promise<void> {
    const ipt = this.iptablesBin(family);
    try {
      await execAsync(
        `${ipt} ${IPT_WAIT} -C INPUT -p tcp -m multiport ` +
          `--dports ${this.PORT_MIN}:${this.PORT_MAX} -j ACCEPT 2>/dev/null`,
      );
    } catch {
      // -I (вставка в начало) — чтобы ACCEPT попал раньше любого DROP.
      await execAsync(
        `${ipt} ${IPT_WAIT} -I INPUT 1 -p tcp -m multiport ` +
          `--dports ${this.PORT_MIN}:${this.PORT_MAX} -j ACCEPT`,
      );
    }
  }

  /**
   * Сохранение правил/ipset'ов на диск с atomic-rename.
   * Прямой `ipset save > /etc/ipset.conf` через shell не атомарный — при
   * SIGKILL/ENOSPC файл остаётся усечённым, на boot'е ipset-persistent
   * падает и lockdown не восстанавливается. Пишем во временный файл,
   * затем rename — на ext4 это атомарно.
   */
  private async persist(): Promise<void> {
    const target = '/etc/ipset.conf';
    const tmp = `${target}.tmp.${process.pid}.${Date.now()}`;
    try {
      const { stdout } = await execAsync('ipset save', {
        maxBuffer: 100 * 1024 * 1024,
      });
      await writeFile(tmp, stdout, 'utf-8');
      await rename(tmp, target);
    } catch (err) {
      this.logger.warn(
        `ipset persist failed: ${(err as Error).message} — runtime state не пострадал, но reboot восстановит старую копию`,
      );
      await unlink(tmp).catch(() => {});
    }

    // netfilter-persistent сам пишет /etc/iptables/rules.v{4,6} через
    // iptables-save (rename внутри плагина) — отдельный atomic-shim не нужен.
    // Логируем ошибку (диск полный / пакет не установлен) — раньше двойное
    // подавление прятало проблему, и оператор не знал что reboot потеряет правила.
    try {
      await execAsync('netfilter-persistent save');
    } catch (err) {
      this.logger.warn(
        `netfilter-persistent save failed: ${(err as Error).message} — iptables правила НЕ сохранены, reboot потеряет lockdown`,
      );
    }
  }

  private async selfCheck(): Promise<{
    v4Rule: boolean;
    v6Rule: boolean;
    v4SetSize: number;
    v6SetSize: number;
  }> {
    const [v4Rule, v6Rule, v4SetSize, v6SetSize] = await Promise.all([
      this.isEnabled('v4'),
      this.ipv6Enabled ? this.isEnabled('v6') : Promise.resolve(false),
      this.whitelistSize('v4'),
      this.ipv6Enabled ? this.whitelistSize('v6') : Promise.resolve(0),
    ]);
    return { v4Rule, v6Rule, v4SetSize, v6SetSize };
  }

  private async listSet(set: string, limit: number): Promise<string[]> {
    try {
      // Для v4 — IP начинаются с цифры; для v6 — с hex или `:` (для `::1`,
      // `::/0`). Заголовочные строки (`Name:`, `Type:`, `Header:`, `Size...`,
      // `References:`, `Number...`, `Members:`) начинаются с заглавной A-Z.
      // Класс `[0-9a-fA-F:]` ловит всё содержимое и не зацепляет заголовки
      // (там только в `:` середина, не первая позиция, плюс A-F совпадает —
      // но у заголовков ВСЕГДА вторая буква строчная, что регексу не важно).
      // Поэтому добавляем явный исключающий шаблон.
      const { stdout } = await execAsync(
        `ipset list ${set} | awk '/^[0-9a-fA-F:]/ && !/^(Name|Type|Header|Size|References|Number|Members|Revision):/ {print; if (++c >= ${limit}) exit}'`,
        { maxBuffer: 100 * 1024 * 1024 },
      );
      return stdout.trim().split('\n').filter(Boolean);
    } catch {
      return [];
    }
  }

  // ═══════════════════════════════════════════════════════════
  //  Validation / normalization
  // ═══════════════════════════════════════════════════════════

  private dedupeAndValidate(ips: string[]): {
    v4: string[];
    v6: string[];
    invalid: number;
    duplicates: number;
  } {
    const v4Set = new Set<string>();
    const v6Set = new Set<string>();
    let invalid = 0;
    let duplicates = 0;

    for (const raw of ips) {
      const ip = raw.trim();
      if (IP_OR_CIDR_REGEX.test(ip)) {
        const norm = this.normalizeV4(ip);
        if (v4Set.has(norm)) {
          duplicates++;
        } else {
          v4Set.add(norm);
        }
      } else if (IP_OR_CIDR_V6_REGEX.test(ip)) {
        const norm = this.normalizeV6(ip);
        if (norm === null) {
          invalid++;
          continue;
        }
        if (v6Set.has(norm)) {
          duplicates++;
        } else {
          v6Set.add(norm);
        }
      } else {
        invalid++;
      }
    }

    return {
      v4: Array.from(v4Set),
      v6: Array.from(v6Set),
      invalid,
      duplicates,
    };
  }

  /**
   * Нормализация v4 CIDR к network-boundary + обрезание leading zeros в октетах.
   * ipset hash:net отказывается добавлять "130.0.238.1/24" (маска не на границе).
   */
  private normalizeV4(entry: string): string {
    const [ipPart, maskStr] = entry.split('/');
    const octets = ipPart.split('.').map((o) => Number(o));
    const ipInt =
      ((octets[0] << 24) |
        (octets[1] << 16) |
        (octets[2] << 8) |
        octets[3]) >>>
      0;

    if (maskStr === undefined) {
      return this.intToIp(ipInt);
    }

    const mask = parseInt(maskStr, 10);
    if (mask === 32) {
      // /32 эквивалент одиночного IP — ipset хранит без маски, дедуп корректен.
      return this.intToIp(ipInt);
    }

    const maskInt = mask === 0 ? 0 : (0xffffffff << (32 - mask)) >>> 0;
    const network = (ipInt & maskInt) >>> 0;
    return `${this.intToIp(network)}/${mask}`;
  }

  private intToIp(n: number): string {
    return [
      (n >>> 24) & 0xff,
      (n >>> 16) & 0xff,
      (n >>> 8) & 0xff,
      n & 0xff,
    ].join('.');
  }

  /**
   * Нормализация v6 CIDR к network-boundary + canonical form (lowercase,
   * compressed). Возвращает null если строка не парсится как валидный v6.
   */
  private normalizeV6(entry: string): string | null {
    const [ipPart, maskStr] = entry.split('/');
    if (!isIPv6(ipPart)) return null;

    let big: bigint;
    try {
      big = this.v6ToBigInt(ipPart);
    } catch {
      return null;
    }

    const mask = maskStr === undefined ? 128 : parseInt(maskStr, 10);
    if (!Number.isInteger(mask) || mask < 0 || mask > 128) return null;

    if (mask === 128) {
      return this.bigIntToV6(big);
    }
    const maskBig =
      mask === 0 ? 0n : ((1n << BigInt(mask)) - 1n) << BigInt(128 - mask);
    const network = big & maskBig;
    return `${this.bigIntToV6(network)}/${mask}`;
  }

  private v6ToBigInt(ip: string): bigint {
    // Раскрываем `::` до полной формы.
    const parts = ip.split('::');
    if (parts.length > 2) throw new Error('invalid v6');
    const head = parts[0] === '' ? [] : parts[0].split(':');
    const tail =
      parts.length === 2
        ? parts[1] === ''
          ? []
          : parts[1].split(':')
        : [];
    if (parts.length === 1 && head.length !== 8) throw new Error('invalid v6');
    const missing = 8 - head.length - tail.length;
    if (missing < 0) throw new Error('invalid v6');
    const segments = [...head, ...Array(missing).fill('0'), ...tail];
    let result = 0n;
    for (const seg of segments) {
      const n = parseInt(seg, 16);
      if (Number.isNaN(n) || n < 0 || n > 0xffff) throw new Error('invalid v6');
      result = (result << 16n) | BigInt(n);
    }
    return result;
  }

  private bigIntToV6(n: bigint): string {
    // Производим канонический compressed lowercase v6 (RFC 5952).
    const segments: string[] = [];
    for (let i = 7; i >= 0; i--) {
      const seg = (n >> BigInt(i * 16)) & 0xffffn;
      segments.push(seg.toString(16));
    }
    // Найти самую длинную серию нулей (>=2) для замены на ::
    let bestStart = -1;
    let bestLen = 0;
    let curStart = -1;
    let curLen = 0;
    for (let i = 0; i < segments.length; i++) {
      if (segments[i] === '0') {
        if (curStart === -1) curStart = i;
        curLen++;
        if (curLen > bestLen) {
          bestLen = curLen;
          bestStart = curStart;
        }
      } else {
        curStart = -1;
        curLen = 0;
      }
    }
    if (bestLen >= 2) {
      const before = segments.slice(0, bestStart).join(':');
      const after = segments.slice(bestStart + bestLen).join(':');
      return `${before}::${after}`;
    }
    return segments.join(':');
  }
}
