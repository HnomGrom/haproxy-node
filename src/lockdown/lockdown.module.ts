import { Module } from '@nestjs/common';
import { LockdownController } from './lockdown.controller';
import { LockdownService } from './lockdown.service';

@Module({
  controllers: [LockdownController],
  providers: [LockdownService],
  exports: [LockdownService],
})
export class LockdownModule {}
