import {
  CanActivate,
  ExecutionContext,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { timingSafeEqual } from 'crypto';
import { Request } from 'express';

@Injectable()
export class ApiKeyGuard implements CanActivate {
  constructor(private readonly config: ConfigService) {}

  canActivate(context: ExecutionContext): boolean {
    const request = context.switchToHttp().getRequest<Request>();
    const provided = request.headers['x-api-key'];
    const expected = this.config.get<string>('API_KEY');

    if (!expected || typeof provided !== 'string' || !provided) {
      throw new UnauthorizedException('Invalid API key');
    }

    if (!this.safeEqual(provided, expected)) {
      throw new UnauthorizedException('Invalid API key');
    }

    return true;
  }

  // timing-safe сравнение. timingSafeEqual требует равной длины буферов —
  // иначе кидает RangeError, что само по себе выдаёт длину. Поэтому сначала
  // выравниваем длины через Buffer.alloc(maxLen) и потом сравниваем.
  // Дополнительное сравнение длин в конце — чтобы строки разной длины
  // никогда не были равны, даже если префикс совпал.
  private safeEqual(a: string, b: string): boolean {
    const aBuf = Buffer.from(a, 'utf-8');
    const bBuf = Buffer.from(b, 'utf-8');
    const maxLen = Math.max(aBuf.length, bBuf.length);
    const aPad = Buffer.alloc(maxLen);
    const bPad = Buffer.alloc(maxLen);
    aBuf.copy(aPad);
    bBuf.copy(bPad);
    return timingSafeEqual(aPad, bPad) && aBuf.length === bBuf.length;
  }
}
