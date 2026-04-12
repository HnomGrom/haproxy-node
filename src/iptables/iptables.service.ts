import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

const CHAIN_NAME = 'HAPROXY_FALLBACK';

@Injectable()
export class IptablesService {
  private readonly logger = new Logger(IptablesService.name);
  private readonly fallbackPort: number;
  private readonly apiPort: number;

  constructor(private readonly config: ConfigService) {
    this.fallbackPort = Number(this.config.get('FALLBACK_PORT', 59999));
    this.apiPort = Number(this.config.get('PORT', 3000));
  }

  async applyRules(serverPorts: number[]): Promise<void> {
    try {
      await this.ensureChainExists();
      await this.flushChain();

      // Protect SSH
      await this.addReturn(22);

      // Protect API port
      await this.addReturn(this.apiPort);

      // Protect fallback port itself (avoid redirect loop)
      await this.addReturn(this.fallbackPort);

      // Protect each server frontend port
      for (const port of serverPorts) {
        await this.addReturn(port);
      }

      // Everything else → redirect to fallback
      await execAsync(
        `iptables -t nat -A ${CHAIN_NAME} -p tcp -j REDIRECT --to-port ${this.fallbackPort}`,
      );

      // Attach chain to PREROUTING if not already attached
      await this.attachToPrerouting();

      this.logger.log(
        `iptables rules applied: ${serverPorts.length} server ports protected, fallback on :${this.fallbackPort}`,
      );
    } catch (error) {
      this.logger.error('Failed to apply iptables rules', error);
      throw error;
    }
  }

  async cleanup(): Promise<void> {
    try {
      await this.detachFromPrerouting();
      await this.flushChain();
      await execAsync(`iptables -t nat -X ${CHAIN_NAME}`).catch(() => {});
      this.logger.log('iptables rules cleaned up');
    } catch (error) {
      this.logger.error('Failed to cleanup iptables rules', error);
    }
  }

  private async ensureChainExists(): Promise<void> {
    try {
      await execAsync(`iptables -t nat -n -L ${CHAIN_NAME}`);
    } catch {
      await execAsync(`iptables -t nat -N ${CHAIN_NAME}`);
    }
  }

  private async flushChain(): Promise<void> {
    await execAsync(`iptables -t nat -F ${CHAIN_NAME}`);
  }

  private async addReturn(port: number): Promise<void> {
    await execAsync(
      `iptables -t nat -A ${CHAIN_NAME} -p tcp --dport ${port} -j RETURN`,
    );
  }

  private async attachToPrerouting(): Promise<void> {
    try {
      const { stdout } = await execAsync(
        `iptables -t nat -S PREROUTING`,
      );

      if (!stdout.includes(CHAIN_NAME)) {
        await execAsync(
          `iptables -t nat -A PREROUTING -p tcp -j ${CHAIN_NAME}`,
        );
      }
    } catch {
      await execAsync(
        `iptables -t nat -A PREROUTING -p tcp -j ${CHAIN_NAME}`,
      );
    }
  }

  private async detachFromPrerouting(): Promise<void> {
    try {
      // Remove all references to our chain from PREROUTING
      let hasRule = true;
      while (hasRule) {
        await execAsync(
          `iptables -t nat -D PREROUTING -p tcp -j ${CHAIN_NAME}`,
        );
      }
    } catch {
      // No more rules to remove
    }
  }
}
