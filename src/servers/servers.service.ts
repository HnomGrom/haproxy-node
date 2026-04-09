import { BadRequestException, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { randomBytes } from 'crypto';
import { PrismaService } from '../prisma/prisma.service';
import { HaproxyService } from '../haproxy/haproxy.service';
import { CreateServerDto } from './dto/create-server.dto';
import { Server } from '../../generated/prisma/client';

@Injectable()
export class ServersService {
  private readonly portMin: number;
  private readonly portMax: number;

  constructor(
    private readonly prisma: PrismaService,
    private readonly haproxy: HaproxyService,
    private readonly config: ConfigService,
  ) {
    this.portMin = this.config.get<number>('FRONTEND_PORT_MIN', 10000);
    this.portMax = this.config.get<number>('FRONTEND_PORT_MAX', 65000);
  }

  async findAll(): Promise<Server[]> {
    return this.prisma.server.findMany({ orderBy: { id: 'asc' } });
  }

  async create(dto: CreateServerDto): Promise<Server> {
    const frontendPort = await this.allocatePort();
    const name = 'node_' + randomBytes(4).toString('hex');

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
  }

  async remove(id: number): Promise<void> {
    const server = await this.prisma.server.findUnique({ where: { id } });
    if (!server) {
      throw new BadRequestException(`Server with id ${id} not found`);
    }

    await this.prisma.server.delete({ where: { id } });

    try {
      const allServers = await this.findAll();
      await this.haproxy.applyConfig(allServers);
    } catch {
      await this.prisma.server.create({ data: server });
      throw new BadRequestException(
        'Failed to apply HAProxy config — server not removed',
      );
    }
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
