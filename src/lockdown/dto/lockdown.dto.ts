import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
} from 'class-validator';

// IPv4 (1.2.3.4) или IPv4+CIDR mask 0-32 (130.0.238.0/24).
// Не проверяет network-boundary — нормализация в LockdownService.normalizeEntry().
export const IP_OR_CIDR_REGEX =
  /^(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d?\d)(?:\/(?:3[0-2]|[12]?\d))?$/;

export class IpListDto {
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(2_000_000)
  @Matches(IP_OR_CIDR_REGEX, {
    each: true,
    message: 'Each entry must be IPv4 or CIDR (e.g., "1.2.3.4" or "130.0.238.0/24")',
  })
  ips: string[];

  @IsOptional()
  @IsString()
  @MaxLength(256)
  reason?: string;
}

export class LockdownOffDto {
  @IsOptional()
  @IsString()
  @MaxLength(256)
  reason?: string;
}
