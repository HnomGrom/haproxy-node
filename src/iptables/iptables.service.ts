import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

const LEGACY_CHAIN = 'HAPROXY_FALLBACK';

/**
 * Legacy: ранее служба создавала NAT-цепочку HAPROXY_FALLBACK,
 * которая редиректила неизвестный трафик на fallback-порт. Это делало
 * HAProxy мишенью для сканеров.
 *
 * Теперь неизвестные порты дропаются policy INPUT DROP (см. install.sh).
 * Служба только удаляет старую цепочку — для миграции с прошлых версий.
 */
@Injectable()
export class IptablesService implements OnModuleInit {
  private readonly logger = new Logger(IptablesService.name);

  async onModuleInit(): Promise<void> {
    await this.cleanup();
  }

  // Вызывается из HaproxyService.applyConfig() — для совместимости. Ничего не создаёт.
  async applyRules(_serverPorts: number[]): Promise<void> {
    await this.cleanup();
  }

  async cleanup(): Promise<void> {
    try {
      await execAsync(
        `iptables -t nat -D PREROUTING -p tcp -j ${LEGACY_CHAIN} 2>/dev/null || true`,
      );
      await execAsync(`iptables -t nat -F ${LEGACY_CHAIN} 2>/dev/null || true`);
      await execAsync(`iptables -t nat -X ${LEGACY_CHAIN} 2>/dev/null || true`);
      this.logger.log(`Legacy NAT chain ${LEGACY_CHAIN} removed (if existed)`);
    } catch (error) {
      this.logger.warn('Legacy NAT cleanup returned error (non-fatal)', error);
    }
  }
}
