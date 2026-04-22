import { Injectable, Logger } from '@nestjs/common';
import { exec } from 'child_process';
import { writeFile, mkdir } from 'fs/promises';
import { promisify } from 'util';

const execAsync = promisify(exec);

/**
 * Синхронизация backend-IP в CrowdSec whitelist.
 * При добавлении/удалении сервера через API автоматически обновляет
 * /etc/crowdsec/parsers/s02-enrich/whitelist-backend.yaml
 * и делает reload CrowdSec.
 *
 * Если CrowdSec не установлен — все методы no-op (логируется debug).
 */
@Injectable()
export class CrowdsecService {
  private readonly logger = new Logger(CrowdsecService.name);
  private readonly WHITELIST_DIR = '/etc/crowdsec/parsers/s02-enrich';
  private readonly WHITELIST_PATH = `${this.WHITELIST_DIR}/whitelist-backend.yaml`;

  /** Проверить установлен ли CrowdSec на сервере */
  async isInstalled(): Promise<boolean> {
    try {
      await execAsync('which cscli', { timeout: 2000 });
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Обновить whitelist backend IP.
   * Вызывается из HaproxyService.applyConfig() при каждом изменении списка серверов.
   */
  async syncBackendWhitelist(ips: string[]): Promise<void> {
    if (!(await this.isInstalled())) {
      this.logger.debug('CrowdSec не установлен, skip whitelist sync');
      return;
    }

    const uniqueIps = Array.from(new Set(['127.0.0.1', ...ips.filter(Boolean)]));
    const yaml = this.buildWhitelistYaml(uniqueIps);

    try {
      await mkdir(this.WHITELIST_DIR, { recursive: true });
      await writeFile(this.WHITELIST_PATH, yaml, 'utf-8');

      // Пытаемся сделать reload (быстрый), если не получилось — restart
      try {
        await execAsync('systemctl reload crowdsec', { timeout: 10000 });
      } catch {
        await execAsync('systemctl restart crowdsec', { timeout: 15000 }).catch(() => {});
      }

      this.logger.log(
        `CrowdSec backend whitelist обновлён (${uniqueIps.length} IP)`,
      );
    } catch (error) {
      this.logger.warn('Ошибка при обновлении CrowdSec whitelist (non-critical)', error);
    }
  }

  private buildWhitelistYaml(ips: string[]): string {
    const lines = [
      'name: local/backend-whitelist',
      'description: "Backend Xray nodes — auto-generated from database"',
      'whitelist:',
      '  reason: "backend servers (auto)"',
      '  ip:',
    ];
    for (const ip of ips) {
      lines.push(`    - "${ip}"`);
    }
    return lines.join('\n') + '\n';
  }
}
