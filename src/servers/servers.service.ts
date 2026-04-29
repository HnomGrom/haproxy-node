import {
  BadRequestException,
  ConflictException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { randomBytes } from 'crypto';
import { Mutex } from 'async-mutex';
import { Socket } from 'net';
import { PrismaService } from '../prisma/prisma.service';
import { HaproxyService } from '../haproxy/haproxy.service';
import { CreateServerDto } from './dto/create-server.dto';
import { Server } from '../../generated/prisma/client';

@Injectable()
export class ServersService {
  private readonly portMin: number;
  private readonly portMax: number;
  // Сериализует create()/remove() — иначе параллельные create() читают
  // одинаковый snapshot used-портов и оба выбирают тот же frontendPort,
  // один из insert'ов падает на @unique. Также защищает order
  // delete→applyConfig→rollback в remove().
  private readonly mutex = new Mutex();

  constructor(
    private readonly prisma: PrismaService,
    private readonly haproxy: HaproxyService,
    private readonly config: ConfigService,
  ) {
    this.portMin = Number(this.config.get('FRONTEND_PORT_MIN', 10000));
    this.portMax = Number(this.config.get('FRONTEND_PORT_MAX', 65000));
  }

  async findAll(): Promise<Server[]> {
    return this.prisma.server.findMany({ orderBy: { id: 'asc' } });
  }

  async findAllWithFlags(): Promise<(Server & { duplicateIp: boolean })[]> {
    const servers = await this.findAll();
    // Diagnostic flag: после @@unique([ip, backendPort]) дубликаты теоретически
    // невозможны, но на легаси-БД до миграции могут остаться. Помечаем все
    // строки с дубликатным `ip`, чтобы оператор видел проблему в /servers.
    const ipCount = new Map<string, number>();
    for (const s of servers) ipCount.set(s.ip, (ipCount.get(s.ip) ?? 0) + 1);
    return servers.map((s) => ({
      ...s,
      duplicateIp: (ipCount.get(s.ip) ?? 0) > 1,
    }));
  }

  async checkHealth(
    id: number,
  ): Promise<{ id: number; ip: string; port: number; up: boolean; error: string | null; latencyMs: number | null }> {
    const server = await this.prisma.server.findUnique({ where: { id } });
    if (!server) throw new NotFoundException(`Server with id ${id} not found`);
    const probe = await this.tcpProbe(server.ip, server.backendPort, 3_000);
    return {
      id: server.id,
      ip: server.ip,
      port: server.backendPort,
      up: probe.up,
      error: probe.error,
      latencyMs: probe.latencyMs,
    };
  }

  // Простая TCP-проба: connect → close. Не делает TLS-handshake (xray бэкенд
  // отвечает только на корректный TLS hello, иначе подвешивает коннект).
  // Если порт открыт и accept проходит — backend как минимум жив на сетевом уровне.
  private tcpProbe(
    host: string,
    port: number,
    timeoutMs: number,
  ): Promise<{ up: boolean; error: string | null; latencyMs: number | null }> {
    return new Promise((resolve) => {
      const start = Date.now();
      const socket = new Socket();
      let done = false;
      const finish = (up: boolean, error: string | null) => {
        if (done) return;
        done = true;
        socket.destroy();
        resolve({
          up,
          error,
          latencyMs: up ? Date.now() - start : null,
        });
      };
      socket.setTimeout(timeoutMs);
      socket.once('connect', () => finish(true, null));
      socket.once('timeout', () => finish(false, 'timeout'));
      socket.once('error', (err) => finish(false, err.message));
      // socket.connect() обычно не throw'ит синхронно (ошибки идут в 'error'),
      // но на edge-case'ах (мусорный port=NaN после strict-mode TS изменений
      // или ENOMEM на создании сокета) может. Без try/catch Promise завис бы
      // до HTTP-таймаута клиента.
      try {
        socket.connect(port, host);
      } catch (err) {
        finish(false, (err as Error).message);
      }
    });
  }

  async create(dto: CreateServerDto): Promise<Server> {
    return this.mutex.runExclusive(async () => {
      const existing = await this.prisma.server.findFirst({
        where: { ip: dto.ip, backendPort: dto.backendPort },
      });
      if (existing) {
        throw new ConflictException(
          `Server with ip=${dto.ip} backendPort=${dto.backendPort} already exists (id=${existing.id})`,
        );
      }

      const frontendPort = await this.allocatePort();
      const name = 'node_' + randomBytes(8).toString('hex');

      const server = await this.prisma.server.create({
        data: {
          name,
          ip: dto.ip,
          backendPort: dto.backendPort,
          frontendPort,
        },
      });

      try {
        const allServers = await this.findAll();
        await this.haproxy.applyConfig(allServers);
      } catch {
        await this.prisma.server.delete({ where: { id: server.id } });
        throw new BadRequestException(
          'Failed to apply HAProxy config — server not added',
        );
      }

      return server;
    });
  }

  async remove(id: number): Promise<void> {
    return this.mutex.runExclusive(async () => {
      const server = await this.prisma.server.findUnique({ where: { id } });
      if (!server) {
        throw new BadRequestException(`Server with id ${id} not found`);
      }

      // Транзакция: delete + check applyConfig внутри одного scope.
      // Если applyConfig провалится — Prisma откатит delete. Сам HAProxy
      // конфиг откатывается по-старому в HaproxyService через backup.
      try {
        await this.prisma.$transaction(async (tx) => {
          await tx.server.delete({ where: { id } });
          const remaining = await tx.server.findMany({
            orderBy: { id: 'asc' },
          });
          await this.haproxy.applyConfig(remaining);
        });
      } catch {
        throw new BadRequestException(
          'Failed to apply HAProxy config — server not removed',
        );
      }
    });
  }

  private async allocatePort(): Promise<number> {
    const usedPorts = await this.prisma.server.findMany({
      select: { frontendPort: true },
    });
    const usedSet = new Set(usedPorts.map((s) => s.frontendPort));

    for (let port = this.portMin; port <= this.portMax; port++) {
      if (!usedSet.has(port)) {
        return port;
      }
    }

    throw new BadRequestException('No available frontend ports');
  }
}
