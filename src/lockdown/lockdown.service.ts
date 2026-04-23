import {
  BadRequestException,
  Injectable,
  Logger,
  OnModuleInit,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { exec } from 'child_process';
import { writeFile, unlink } from 'fs/promises';
import { promisify } from 'util';
import { PrismaService } from '../prisma/prisma.service';
import { IP_OR_CIDR_REGEX } from './dto/lockdown.dto';

const execAsync = promisify(exec);

@Injectable()
export class LockdownService implements OnModuleInit {
  private readonly logger = new Logger(LockdownService.name);

  private readonly SET = 'vless_lockdown';
  private readonly TMP_SET_PREFIX = 'vless_lockdown_tmp';
  private readonly MAX_ELEM = 1_000_000;
  private readonly HASH_SIZE = 65536;
  private readonly PORT_MIN: number;
  private readonly PORT_MAX: number;

  constructor(
    private readonly config: ConfigService,
    private readonly prisma: PrismaService,
  ) {
    this.PORT_MIN = Number(this.config.get('FRONTEND_PORT_MIN', 10000));
    this.PORT_MAX = Number(this.config.get('FRONTEND_PORT_MAX', 65000));
  }

  async onModuleInit(): Promise<void> {
    // Гарантируем существование ipset — чтобы incremental-add'ы работали
    // даже когда lockdown не активирован (subscription-api накапливает IP).
    await this.ensureIpset();
  }

  // ═══════════════════════════════════════════════════════════
  //  PUBLIC: IPSET content management
  // ═══════════════════════════════════════════════════════════

  async addIps(
    ips: string[],
  ): Promise<{ requested: number; added: number; skipped: number }> {
    const validIps = this.dedupeAndValidate(ips);
    await this.ensureIpset();

    if (validIps.length === 0) {
      return { requested: ips.length, added: 0, skipped: ips.length };
    }

    // Счёт added через diff size — под конкурентной нагрузкой может врать
    // (две параллельные addIps считают before/after пересечённо). Для наших
    // целей (вывод в лог) это приемлемо; точный учёт — через prisma.event.
    const before = await this.whitelistSize();

    if (validIps.length <= 10) {
      // Для маленьких списков — прямой ipset add (нет оверхеда на tmp-файл).
      // -exist подавляет ошибку "already added".
      for (const ip of validIps) {
        await execAsync(`ipset add ${this.SET} ${ip} -exist`).catch((err) =>
          this.logger.warn(`ipset add ${ip} failed: ${err.message}`),
        );
      }
    } else {
      await this.batchIpsetOperation(validIps, 'add');
    }

    const after = await this.whitelistSize();
    const added = Math.max(0, after - before);
    const skipped = ips.length - added;

    await this.persist();
    await this.prisma.lockdownEvent.create({
      data: { action: 'add', source: 'api', reason: null, ipCount: added },
    });

    this.logger.log(
      `Added ${added} IPs/CIDRs (requested ${ips.length}, skipped ${skipped})`,
    );
    return { requested: ips.length, added, skipped };
  }

  async removeIps(
    ips: string[],
  ): Promise<{ requested: number; removed: number }> {
    const validIps = this.dedupeAndValidate(ips);
    await this.ensureIpset();

    if (validIps.length === 0) {
      return { requested: ips.length, removed: 0 };
    }

    const before = await this.whitelistSize();
    // -exist в batchIpsetOperation подавляет "not in set" — удаляем что есть,
    // остальное молча пропускаем.
    await this.batchIpsetOperation(validIps, 'del');
    const after = await this.whitelistSize();
    const removed = Math.max(0, before - after);

    await this.persist();
    await this.prisma.lockdownEvent.create({
      data: { action: 'remove', source: 'api', reason: null, ipCount: removed },
    });

    this.logger.log(`Removed ${removed} IPs/CIDRs (requested ${ips.length})`);
    return { requested: ips.length, removed };
  }

  async listIps(limit = 1000): Promise<string[]> {
    await this.ensureIpset();
    try {
      const { stdout } = await execAsync(
        `ipset list ${this.SET} | awk '/^[0-9]+\\./ {print; if (++c >= ${limit}) exit}'`,
        { maxBuffer: 100 * 1024 * 1024 },
      );
      return stdout.trim().split('\n').filter(Boolean);
    } catch {
      return [];
    }
  }

  // ═══════════════════════════════════════════════════════════
  //  PUBLIC: lockdown toggle
  // ═══════════════════════════════════════════════════════════

  /**
   * Активировать lockdown со списком IP/CIDR одним запросом.
   *
   * Порядок важен на двух уровнях:
   *   1. Сначала atomic swap содержимого ipset (bulkLoadIps).
   *      Иначе iptables-правило match-set есть, а в set пусто → клиентам дропы.
   *   2. Внутри ensureIptablesRule: INSERT match-set правила ПЕРЕД
   *      DELETE общего ACCEPT — без окна "ни одного ACCEPT".
   */
  async enable(
    ips: string[],
    reason?: string,
  ): Promise<{ enabled: boolean; whitelistSize: number }> {
    const validIps = this.dedupeAndValidate(ips);

    if (validIps.length === 0) {
      // Защита от самоблокировки — пустой whitelist отрезал бы всех клиентов.
      throw new BadRequestException(
        'Empty or all-invalid ips[] — refusing to activate lockdown (would block all clients)',
      );
    }

    this.logger.log(
      `Activating lockdown: ${validIps.length} entries (reason: ${reason ?? 'n/a'})`,
    );

    await this.bulkLoadIps(validIps);
    await this.ensureIptablesRule();
    await this.persist();

    await this.prisma.lockdownEvent.create({
      data: {
        action: 'enable',
        source: 'api',
        reason: reason ?? null,
        ipCount: validIps.length,
      },
    });

    this.logger.log(`Lockdown ENABLED (whitelist: ${validIps.length} entries)`);
    return { enabled: true, whitelistSize: validIps.length };
  }

  /**
   * Деактивировать — вернуть общий ACCEPT на VLESS-диапазон.
   * Содержимое ipset сохраняется для следующей активации.
   *
   * Порядок зеркальный enable(): сначала INSERT ACCEPT-all, потом DELETE
   * match-set — без окна без ACCEPT.
   */
  async disable(reason?: string): Promise<{ enabled: boolean }> {
    await this.ensureFallbackAcceptRule();
    await this.removeIptablesRule();
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
  }

  async status() {
    const [enabled, count, lastEvent] = await Promise.all([
      this.isEnabled(),
      this.whitelistSize(),
      this.prisma.lockdownEvent.findFirst({ orderBy: { createdAt: 'desc' } }),
    ]);
    return { enabled, whitelistSize: count, lastEvent };
  }

  async isEnabled(): Promise<boolean> {
    try {
      await execAsync(
        `iptables -C INPUT -p tcp -m multiport ` +
          `--dports ${this.PORT_MIN}:${this.PORT_MAX} ` +
          `-m set --match-set ${this.SET} src -j ACCEPT 2>/dev/null`,
      );
      return true;
    } catch {
      return false;
    }
  }

  async whitelistSize(): Promise<number> {
    try {
      // -t (terse) не дампит все entries — O(1) даже для 1M записей.
      const { stdout } = await execAsync(
        `ipset list -t ${this.SET} 2>/dev/null | awk -F': ' '/Number of entries/ {print $2}'`,
      );
      return parseInt(stdout.trim(), 10) || 0;
    } catch {
      return 0;
    }
  }

  // ═══════════════════════════════════════════════════════════
  //  PRIVATE
  // ═══════════════════════════════════════════════════════════

  private get setArgs(): string {
    // hash:net поддерживает и точные IP, и CIDR-диапазоны. Lookup O(1).
    return `hash:net maxelem ${this.MAX_ELEM} hashsize ${this.HASH_SIZE} family inet`;
  }

  private async ensureIpset(): Promise<void> {
    // -exist — ipset-нативный флаг идемпотентности (не ошибается если set уже есть).
    await execAsync(`ipset create ${this.SET} ${this.setArgs} -exist`);
  }

  private newTmpSetName(): string {
    // Уникальное имя защищает от коллизии при параллельных enable() вызовах.
    return `${this.TMP_SET_PREFIX}_${process.pid}_${Date.now()}_${Math.floor(
      Math.random() * 1e6,
    )}`;
  }

  /**
   * Atomic bulk replace содержимого ipset через restore+swap.
   * 100k записей за 1-3 сек. Содержимое меняется атомарно.
   *
   * tmp-set создаётся и наполняется снаружи restore-файла — `destroy`
   * внутри restore упал бы на первом запуске (set ещё не существует;
   * `-!` эту ошибку не подавляет).
   */
  private async bulkLoadIps(ips: string[]): Promise<void> {
    await this.ensureIpset();

    const tmpSet = this.newTmpSetName();
    const tmpFile = `/tmp/ipset-lockdown-${process.pid}-${Date.now()}.txt`;

    // tmp-set с ТЕМИ ЖЕ параметрами — иначе swap упадёт на type mismatch.
    await execAsync(`ipset create ${tmpSet} ${this.setArgs} -exist`);
    await execAsync(`ipset flush ${tmpSet}`);

    const lines = ips.map((ip) => `add ${tmpSet} ${ip}`).join('\n') + '\n';
    await writeFile(tmpFile, lines, 'utf-8');

    try {
      // -f (НЕ -file!) — правильный короткий флаг для input-файла.
      // -! подавляет "already added" ошибки на уровне каждой add-строки.
      await execAsync(`ipset restore -! -f ${tmpFile}`, {
        maxBuffer: 100 * 1024 * 1024,
      });
      await execAsync(`ipset swap ${this.SET} ${tmpSet}`);
      await execAsync(`ipset destroy ${tmpSet}`);
    } catch (err) {
      // При падении restore/swap — чистим tmp-set, чтобы не копились "хвосты".
      await execAsync(`ipset destroy ${tmpSet}`).catch(() => {});
      throw err;
    } finally {
      await unlink(tmpFile).catch(() => {});
    }
  }

  private async batchIpsetOperation(
    ips: string[],
    op: 'add' | 'del',
  ): Promise<void> {
    const tmpFile = `/tmp/ipset-${op}-${process.pid}-${Date.now()}.txt`;
    const lines = ips.map((ip) => `${op} ${this.SET} ${ip}`).join('\n') + '\n';
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
   * Активировать match-set правило.
   * INSERT нового правила ДО DELETE общего ACCEPT — без окна без ACCEPT.
   */
  private async ensureIptablesRule(): Promise<void> {
    try {
      await execAsync(
        `iptables -C INPUT -p tcp -m multiport ` +
          `--dports ${this.PORT_MIN}:${this.PORT_MAX} ` +
          `-m set --match-set ${this.SET} src -j ACCEPT 2>/dev/null`,
      );
    } catch {
      await execAsync(
        `iptables -I INPUT 1 -p tcp -m multiport ` +
          `--dports ${this.PORT_MIN}:${this.PORT_MAX} ` +
          `-m set --match-set ${this.SET} src -j ACCEPT`,
      );
    }
    // Общий ACCEPT убираем ПОСЛЕ установки match-set правила.
    await execAsync(
      `iptables -D INPUT -p tcp -m multiport ` +
        `--dports ${this.PORT_MIN}:${this.PORT_MAX} -j ACCEPT 2>/dev/null || true`,
    );
  }

  private async removeIptablesRule(): Promise<void> {
    // Цикл чистит все дубликаты match-set правила (если вдруг случились).
    for (;;) {
      try {
        await execAsync(
          `iptables -D INPUT -p tcp -m multiport ` +
            `--dports ${this.PORT_MIN}:${this.PORT_MAX} ` +
            `-m set --match-set ${this.SET} src -j ACCEPT 2>/dev/null`,
        );
      } catch {
        return;
      }
    }
  }

  private async ensureFallbackAcceptRule(): Promise<void> {
    try {
      await execAsync(
        `iptables -C INPUT -p tcp -m multiport ` +
          `--dports ${this.PORT_MIN}:${this.PORT_MAX} -j ACCEPT 2>/dev/null`,
      );
    } catch {
      // -I (вставка в начало) — чтобы ACCEPT попал раньше любого DROP.
      await execAsync(
        `iptables -I INPUT 1 -p tcp -m multiport ` +
          `--dports ${this.PORT_MIN}:${this.PORT_MAX} -j ACCEPT`,
      );
    }
  }

  private async persist(): Promise<void> {
    // /etc/ipset.conf читается плагином ipset-persistent при boot.
    // netfilter-persistent save — iptables-save через свои плагины.
    await execAsync('ipset save > /etc/ipset.conf 2>/dev/null || true');
    await execAsync('netfilter-persistent save 2>/dev/null || true');
  }

  /**
   * Нормализация CIDR к network-boundary + обрезание leading zeros в октетах.
   *
   * ipset hash:net отказывается добавлять "130.0.238.1/24" (маска не на границе)
   * с ошибкой "Syntax error". -! флаг её не подавляет. Без этой нормализации
   * первый "грязный" CIDR валит весь enable()/addIps().
   */
  private normalizeEntry(entry: string): string {
    const [ipPart, maskStr] = entry.split('/');
    const octets = ipPart.split('.').map((o) => Number(o));
    const ipInt =
      (((octets[0] << 24) |
        (octets[1] << 16) |
        (octets[2] << 8) |
        octets[3]) >>>
        0);

    if (maskStr === undefined) {
      return this.intToIp(ipInt);
    }

    const mask = parseInt(maskStr, 10);
    if (mask === 32) {
      // /32 эквивалент одиночного IP — ipset хранит без маски, дедуп корректен.
      return this.intToIp(ipInt);
    }

    const maskInt =
      mask === 0 ? 0 : ((0xffffffff << (32 - mask)) >>> 0);
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

  private dedupeAndValidate(ips: string[]): string[] {
    // Двойная валидация (DTO + здесь) защищает от вызовов из кода в обход
    // DTO. Используем ту же регулярку (импорт из dto/lockdown.dto.ts).
    return Array.from(
      new Set(
        ips
          .map((ip) => ip.trim())
          .filter((ip) => IP_OR_CIDR_REGEX.test(ip))
          .map((ip) => this.normalizeEntry(ip)),
      ),
    );
  }
}
