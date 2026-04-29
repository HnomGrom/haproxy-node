import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Server } from '../../generated/prisma/client';
import { IptablesService } from '../iptables/iptables.service';
import { exec } from 'child_process';
import { readFile, writeFile } from 'fs/promises';
import { promisify } from 'util';

const execAsync = promisify(exec);

@Injectable()
export class HaproxyService {
  private readonly logger = new Logger(HaproxyService.name);
  private readonly configPath: string;

  constructor(
    private readonly config: ConfigService,
    private readonly iptables: IptablesService,
  ) {
    // Joi-валидация в AppModule гарантирует наличие переменной (default '/etc/haproxy/haproxy.cfg').
    this.configPath = this.config.get<string>('HAPROXY_CONFIG_PATH')!;
  }

  buildConfig(servers: Server[]): string {
    const lines: string[] = [
      'global',
      '    log /dev/log local0',
      '    maxconn 50000',
      '    daemon',
      '',
      'defaults',
      '    log global',
      '    mode tcp',
      '    timeout connect 5s',
      '    timeout client  1h',
      '    timeout server  1h',
      '    timeout tunnel  1h',
      '    timeout client-fin 30s',
      '    timeout server-fin 30s',
    ];

    for (const server of servers) {
      lines.push(
        '',
        `frontend ${server.name}_in`,
        `    bind *:${server.frontendPort}`,
        '    mode tcp',
        // inspect-delay + reject if !TLS-hello: не-TLS-сканеры (типа masscan)
        // получают reject, не съедают backend-коннект и не светят backend
        // через 5-секундный hang. accept TLS-hello — сразу маршрутизация.
        '    tcp-request inspect-delay 5s',
        '    tcp-request content reject if !{ req.ssl_hello_type 1 }',
        '    tcp-request content accept if { req.ssl_hello_type 1 }',
        `    default_backend ${server.name}`,
      );
    }

    for (const server of servers) {
      // check inter 5s rise 1 fall 2: 10 сек до UP (вместо 60с при rise 2 inter 30s).
      // Оператор не успевает подумать "не работает" пока backend поднимается.
      lines.push(
        '',
        `backend ${server.name}`,
        '    mode tcp',
        `    server s_${server.id} ${server.ip}:${server.backendPort} check inter 5s fall 2 rise 1`,
      );
    }

    return lines.join('\n') + '\n';
  }

  async applyConfig(servers: Server[]): Promise<void> {
    let backup: string | null = null;

    try {
      backup = await readFile(this.configPath, 'utf-8').catch(() => null);
    } catch {
      // No existing config — first run
    }

    const newConfig = this.buildConfig(servers);
    await writeFile(this.configPath, newConfig, 'utf-8');

    try {
      await execAsync('haproxy -c -f ' + this.configPath);
      await execAsync('systemctl reload haproxy');
      this.logger.log('HAProxy config applied and reloaded');
    } catch (error) {
      this.logger.error('HAProxy reload failed, rolling back', error);

      if (backup !== null) {
        await writeFile(this.configPath, backup, 'utf-8');
        await execAsync('systemctl reload haproxy').catch(() => {});
      }

      throw error;
    }

    // Apply iptables rules (non-critical — don't rollback HAProxy if this fails)
    try {
      const serverPorts = servers.map((s) => s.frontendPort);
      await this.iptables.applyRules(serverPorts);
    } catch (error) {
      this.logger.error(
        'iptables rules failed — HAProxy is running but fallback redirect is not active',
        error,
      );
    }
  }
}
