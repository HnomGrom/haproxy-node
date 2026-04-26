import { ConfigService } from '@nestjs/config';
import { LockdownService } from './lockdown.service';
import { PrismaService } from '../prisma/prisma.service';

const stubConfig = {
  get: (k: string, d?: unknown) => {
    if (k === 'FRONTEND_PORT_MIN') return 10000;
    if (k === 'FRONTEND_PORT_MAX') return 65000;
    return d;
  },
} as unknown as ConfigService;

const stubPrisma = {} as unknown as PrismaService;

// Помощник для доступа к private — оправдано, чтобы покрыть нормализацию
// без сетевых/iptables зависимостей.
function makeService(): LockdownService {
  return new LockdownService(stubConfig, stubPrisma);
}

describe('LockdownService.normalizeV4 (private)', () => {
  const svc = makeService();
  const norm = (v: string) =>
    (svc as unknown as { normalizeV4: (s: string) => string }).normalizeV4(v);

  it('возвращает одиночный IP без маски', () => {
    expect(norm('1.2.3.4')).toBe('1.2.3.4');
  });

  it('сводит /32 к одиночному IP', () => {
    expect(norm('1.2.3.4/32')).toBe('1.2.3.4');
  });

  it('обрезает не-network bits для /24', () => {
    expect(norm('130.0.238.1/24')).toBe('130.0.238.0/24');
  });

  it('обрабатывает /0', () => {
    expect(norm('1.2.3.4/0')).toBe('0.0.0.0/0');
  });

  it('обрабатывает /16', () => {
    expect(norm('192.168.42.99/16')).toBe('192.168.0.0/16');
  });
});

describe('LockdownService.normalizeV6 (private)', () => {
  const svc = makeService();
  const norm = (v: string) =>
    (
      svc as unknown as { normalizeV6: (s: string) => string | null }
    ).normalizeV6(v);

  it('возвращает canonical compressed для одиночного IPv6', () => {
    expect(norm('2a00:0000:0000:0000:0000:0000:0000:0001')).toBe('2a00::1');
  });

  it('сводит /128 к одиночному IP', () => {
    expect(norm('2a00::1/128')).toBe('2a00::1');
  });

  it('обрезает не-network bits для /64', () => {
    expect(norm('2a00:1234:5678:9abc:dead:beef:0000:0001/64')).toBe(
      '2a00:1234:5678:9abc::/64',
    );
  });

  it('возвращает null на мусоре', () => {
    expect(norm('not-an-ip')).toBe(null);
    expect(norm('2a00:::1')).toBe(null);
  });

  it('обрабатывает /0', () => {
    expect(norm('2a00::1/0')).toBe('::/0');
  });
});

describe('LockdownService.dedupeAndValidate (private)', () => {
  const svc = makeService();
  const dedupe = (ips: string[]) =>
    (
      svc as unknown as {
        dedupeAndValidate: (xs: string[]) => {
          v4: string[];
          v6: string[];
          invalid: number;
          duplicates: number;
        };
      }
    ).dedupeAndValidate(ips);

  it('разделяет v4 и v6, считает invalid + duplicates отдельно', () => {
    const r = dedupe([
      '1.2.3.4',
      '1.2.3.4',
      '1.2.3.4/32',
      'not-ip',
      '2a00::1',
      '2a00::1',
      '2a00::1/128',
    ]);
    expect(r.v4).toEqual(['1.2.3.4']);
    expect(r.v6).toEqual(['2a00::1']);
    expect(r.invalid).toBe(1);
    expect(r.duplicates).toBe(4); // три дубля 1.2.3.4 (норм) + два дубля 2a00::1
  });

  it('обрезает CIDR к network boundary при дедупе', () => {
    const r = dedupe(['10.0.0.5/24', '10.0.0.99/24']);
    expect(r.v4).toEqual(['10.0.0.0/24']);
    expect(r.duplicates).toBe(1);
  });

  it('возвращает пустые массивы и нулевые счётчики на пустом входе', () => {
    expect(dedupe([])).toEqual({ v4: [], v6: [], invalid: 0, duplicates: 0 });
  });
});
