import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

const LEGACY_CHAIN = 'HAPROXY_FALLBACK';

/**
 * Legacy: ранее эта служба создавала NAT-цепочку HAPROXY_FALLBACK,
 * которая редиректила весь неизвестный трафик на fallback-порт.
 * Это создавало удобную цель для DDoS (атакующие бомбили случайные порты,
 * NAT перенаправлял всё в HAProxy).
 *
 * Теперь служба только УБИРАЕТ старую цепочку (миграция) и ничего не создаёт.
 * Неизвестный трафик дропается естественно на уровне ядра (RST от TCP стека,
 * либо INPUT policy DROP если включён lockdown).
 */
@Injectable()
export class IptablesService implements OnModuleInit {
  private readonly logger = new Logger(IptablesService.name);

  async onModuleInit(): Promise<void> {
    await this.cleanup();
  }

  // Вызывается из HaproxyService.applyConfig() — noop для обратной совместимости
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
