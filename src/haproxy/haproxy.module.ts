import { Module } from '@nestjs/common';
import { HaproxyService } from './haproxy.service';
import { IptablesModule } from '../iptables/iptables.module';
import { CrowdsecModule } from '../crowdsec/crowdsec.module';

@Module({
  imports: [IptablesModule, CrowdsecModule],
  providers: [HaproxyService],
  exports: [HaproxyService],
})
export class HaproxyModule {}
