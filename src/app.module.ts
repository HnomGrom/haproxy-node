import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { ThrottlerModule, ThrottlerGuard } from '@nestjs/throttler';
import { APP_GUARD } from '@nestjs/core';
import * as Joi from 'joi';
import { PrismaModule } from './prisma/prisma.module';
import { ServersModule } from './servers/servers.module';
import { LockdownModule } from './lockdown/lockdown.module';
import { HealthModule } from './health/health.module';

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      // Валидация ENV при старте — без неё `Number('abc')` = NaN молча
      // ломает allocatePort (BadRequestException на каждом POST /servers).
      // Joi падает на старте с понятной ошибкой.
      validationSchema: Joi.object({
        DATABASE_URL: Joi.string().required(),
        API_KEY: Joi.string().min(8).required(),
        HAPROXY_CONFIG_PATH: Joi.string().default('/etc/haproxy/haproxy.cfg'),
        PORT: Joi.number().integer().min(1).max(65535).default(3000),
        FRONTEND_PORT_MIN: Joi.number()
          .integer()
          .min(1)
          .max(65535)
          .default(10000),
        FRONTEND_PORT_MAX: Joi.number()
          .integer()
          .min(Joi.ref('FRONTEND_PORT_MIN'))
          .max(65535)
          .default(65000),
        API_ALLOWED_IPS: Joi.string().allow('').optional(),
        API_ALLOWED_IPS_V6: Joi.string().allow('').optional(),
        SSH_ALLOWED_IPS: Joi.string().allow('').optional(),
        SSH_ALLOWED_IPS_V6: Joi.string().allow('').optional(),
        THROTTLE_TTL_MS: Joi.number().integer().min(1000).default(60_000),
        THROTTLE_LIMIT: Joi.number().integer().min(1).default(60),
        TRUST_PROXY: Joi.string().allow('').optional(),
      }),
      validationOptions: {
        abortEarly: false,
        allowUnknown: true,
      },
    }),
    // Глобальный rate-limit: защита от flood'а на /lockdown/on с большим
    // payload'ом (даже с правильным API_KEY). Default 60 req/min на IP —
    // комфортно для Remnawave, больно для злоупотребления. /health исключён
    // через @SkipThrottle() декоратор.
    ThrottlerModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService) => [
        {
          name: 'default',
          ttl: Number(config.get('THROTTLE_TTL_MS', 60_000)),
          limit: Number(config.get('THROTTLE_LIMIT', 60)),
        },
      ],
    }),
    PrismaModule,
    ServersModule,
    LockdownModule,
    HealthModule,
  ],
  providers: [{ provide: APP_GUARD, useClass: ThrottlerGuard }],
})
export class AppModule {}
