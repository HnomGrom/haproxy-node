import { Controller, Get } from '@nestjs/common';
import { SkipThrottle } from '@nestjs/throttler';
import { PrismaService } from '../prisma/prisma.service';

// /health не подпадает под global throttler — k8s liveness / nginx upstream /
// systemd watchdog могут бить чаще раз/сек. Без SkipThrottle лимит 60/мин
// валит legit мониторинг ложными 429.
@SkipThrottle()
@Controller('health')
export class HealthController {
  private readonly startedAt = Date.now();

  constructor(private readonly prisma: PrismaService) {}

  // Без ApiKeyGuard — /health должен отвечать systemd / k8s / monitoring
  // без секрета. Утечки чувствительной информации тут нет (статус + uptime + db-ping).
  @Get()
  async check() {
    let dbOk = false;
    let dbError: string | null = null;
    try {
      await this.prisma.$queryRaw`SELECT 1`;
      dbOk = true;
    } catch (err) {
      dbError = (err as Error).message;
    }

    return {
      status: dbOk ? 'ok' : 'degraded',
      uptimeSec: Math.floor((Date.now() - this.startedAt) / 1000),
      db: dbOk ? 'ok' : { status: 'error', message: dbError },
    };
  }
}
