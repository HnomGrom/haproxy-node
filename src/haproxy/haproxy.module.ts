import { Module } from '@nestjs/common';
import { HaproxyService } from './haproxy.service';
import { IptablesModule } from '../iptables/iptables.module';

@Module({
  imports: [IptablesModule],
  providers: [HaproxyService],
  exports: [HaproxyService],
})
export class HaproxyModule {}
