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
// Не проверяет network-boundary — нормализация в LockdownService.normalizeV4().
export const IP_OR_CIDR_REGEX =
  /^(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d?\d)(?:\/(?:3[0-2]|[12]?\d))?$/;

// IPv6 (любые комбинации hex+colon, включая :: и опционально CIDR /0-128).
// Это shape-фильтр; реальная валидация и canonical-нормализация —
// в LockdownService.normalizeV6() через net.isIPv6() и BigInt-арифметику.
export const IP_OR_CIDR_V6_REGEX =
  /^[0-9a-fA-F:]+(?:\/(?:12[0-8]|1[01]\d|[1-9]?\d))?$/;

// Любой IP/CIDR — v4 или v6. Используется для валидации DTO.
export const IP_OR_CIDR_ANY_REGEX = new RegExp(
  `(${IP_OR_CIDR_REGEX.source.slice(1, -1)})|(${IP_OR_CIDR_V6_REGEX.source.slice(1, -1)})`,
);

export class IpListDto {
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(2_000_000)
  @Matches(IP_OR_CIDR_ANY_REGEX, {
    each: true,
    message:
      'Each entry must be IPv4/IPv6 address or CIDR (e.g., "1.2.3.4", "130.0.238.0/24", "2a00::1", "2a00::/32")',
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
