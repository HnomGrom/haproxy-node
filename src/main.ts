import { NestFactory } from '@nestjs/core';
import { ValidationPipe } from '@nestjs/common';
import { NestExpressApplication } from '@nestjs/platform-express';
import { json } from 'express';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create<NestExpressApplication>(AppModule);

  // 1M IPv4 в JSON ~ 16MB, IPv6 чуть больше. Берём 25MB как комфортный
  // потолок: dwarfs default 100KB, но не 50MB как раньше (50MB-flood
  // на /lockdown/on давал CPU spike даже с throttler — сейчас оба слоя).
  app.use(json({ limit: '25mb' }));

  // Trust proxy — без этого throttler видит IP nginx/HAProxy-фронта вместо
  // клиента и лимитит ВСЕХ как одного. Поведение настраивается через env:
  //   TRUST_PROXY=true       — доверять X-Forwarded-For (за reverse proxy)
  //   TRUST_PROXY=loopback   — стандартный список (loopback,linklocal,uniquelocal)
  //   TRUST_PROXY=10.0.0.1   — конкретный IP/CIDR (можно через запятую)
  //   не задано / false      — direct connection (req.ip = peer)
  const trustProxy = process.env.TRUST_PROXY;
  if (trustProxy && trustProxy !== 'false') {
    app.set(
      'trust proxy',
      trustProxy === 'true' ? true : trustProxy,
    );
  }

  app.useGlobalPipes(new ValidationPipe({ whitelist: true }));

  await app.listen(process.env.PORT ?? 3000);
}
bootstrap();
