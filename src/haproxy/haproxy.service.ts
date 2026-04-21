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
  private readonly allowedSniList: string[];

  constructor(
    private readonly config: ConfigService,
    private readonly iptables: IptablesService,
  ) {
    this.configPath = this.config.get<string>('HAPROXY_CONFIG_PATH');
    const rawSni = this.config.get<string>('ALLOWED_SNI', '') || '';
    this.allowedSniList = rawSni
      .split(',')
      .map((s) => s.trim())
      .filter((s) => s.length > 0);
  }

  buildConfig(servers: Server[]): string {
    const lines: string[] = [
      'global',
      '    log /dev/log local0',
      '    maxconn 100000',
      '    nbthread 4',
      '    stats socket /run/haproxy/admin.sock mode 660 level admin',
      '    stats timeout 30s',
      '    daemon',
      '',
      'defaults',
      '    log global',
      '    mode tcp',
      '    option tcplog',
      '    option dontlognull',
      '    option tcp-smart-accept',
      '    timeout connect 3s',
      '    timeout client  30m',
      '    timeout server  30m',
      '    timeout tunnel  1h',
      '    timeout client-fin 10s',
      '    timeout server-fin 10s',
      '',
      '# Shared abuse-detection table (per source IP, across all frontends)',
      'backend abuse_table',
      '    stick-table type ipv6 size 1m expire 30m store conn_rate(10s),conn_cur,sess_rate(10s),gpc0,gpc0_rate(1m)',
    ];

    const sniAcl =
      this.allowedSniList.length > 0
        ? `{ req.ssl_sni -i ${this.allowedSniList.join(' ')} }`
        : null;

    for (const server of servers) {
      const frontendLines = [
        '',
        `frontend ${server.name}_in`,
        `    bind *:${server.frontendPort}`,
        '    mode tcp',
        '    maxconn 20000',
        '    tcp-request connection track-sc0 src table abuse_table',
        '    tcp-request connection reject if { sc0_get_gpc0 gt 0 }',
        '    tcp-request connection reject if { sc0_conn_rate gt 30 }',
        '    tcp-request connection reject if { sc0_conn_cur gt 50 }',
        '    tcp-request inspect-delay 3s',
        '    tcp-request content reject if !{ req.ssl_hello_type 1 }',
        '    tcp-request content sc-inc-gpc0(0) if !{ req.ssl_hello_type 1 }',
      ];

      if (sniAcl) {
        frontendLines.push(
          `    tcp-request content reject unless ${sniAcl}`,
          `    tcp-request content sc-inc-gpc0(0) unless ${sniAcl}`,
        );
      }

      frontendLines.push(`    default_backend ${server.name}`);
      lines.push(...frontendLines);
    }

    for (const server of servers) {
      lines.push(
        '',
        `backend ${server.name}`,
        '    mode tcp',
        `    server s_${server.id} ${server.ip}:${server.backendPort} check inter 30s fall 3 rise 2`,
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
