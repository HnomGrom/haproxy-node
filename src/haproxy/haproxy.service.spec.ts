import { ConfigService } from '@nestjs/config';
import { HaproxyService } from './haproxy.service';
import { IptablesService } from '../iptables/iptables.service';
import { Server } from '../../generated/prisma/client';

const stubConfig = {
  get: (k: string, d?: unknown) =>
    k === 'HAPROXY_CONFIG_PATH' ? '/etc/haproxy/haproxy.cfg' : d,
} as unknown as ConfigService;

const stubIptables = {} as unknown as IptablesService;

const sampleServer: Server = {
  id: 1,
  name: 'node_aabb',
  ip: '10.0.0.1',
  backendPort: 443,
  frontendPort: 10001,
  createdAt: new Date('2026-01-01T00:00:00Z'),
};

describe('HaproxyService.buildConfig', () => {
  const svc = new HaproxyService(stubConfig, stubIptables);

  it('emits frontend with TLS-only reject', () => {
    const cfg = svc.buildConfig([sampleServer]);
    expect(cfg).toContain('frontend node_aabb_in');
    expect(cfg).toContain('bind *:10001');
    expect(cfg).toContain('tcp-request content reject if !{ req.ssl_hello_type 1 }');
    expect(cfg).toContain('default_backend node_aabb');
  });

  it('emits backend with fast health-check (10s to UP)', () => {
    const cfg = svc.buildConfig([sampleServer]);
    expect(cfg).toContain('backend node_aabb');
    expect(cfg).toContain('server s_1 10.0.0.1:443 check inter 5s fall 2 rise 1');
  });

  it('always begins with global block and ends with newline', () => {
    const cfg = svc.buildConfig([]);
    expect(cfg.startsWith('global\n')).toBe(true);
    expect(cfg.endsWith('\n')).toBe(true);
  });
});
