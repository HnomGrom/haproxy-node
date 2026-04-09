import { Module } from '@nestjs/common';
import { ServersController } from './servers.controller';
import { ServersService } from './servers.service';
import { HaproxyModule } from '../haproxy/haproxy.module';

@Module({
  imports: [HaproxyModule],
  controllers: [ServersController],
  providers: [ServersService],
})
export class ServersModule {}
