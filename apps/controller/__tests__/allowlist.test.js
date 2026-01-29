import { describe, it, expect } from '@jest/globals';
import { isIpAllowed } from '../security/allowlist.js';

describe('IP Allowlist', () => {
    it('should allow any IP when allowlist is empty', () => {
        expect(isIpAllowed('192.168.1.1', [])).toBe(true);
        expect(isIpAllowed('10.0.0.1', [])).toBe(true);
    });
    
    it('should allow exact IP match', () => {
        const allowlist = ['192.168.1.1', '10.0.0.1'];
        expect(isIpAllowed('192.168.1.1', allowlist)).toBe(true);
        expect(isIpAllowed('10.0.0.1', allowlist)).toBe(true);
    });
    
    it('should deny non-matching IP', () => {
        const allowlist = ['192.168.1.1'];
        expect(isIpAllowed('192.168.1.2', allowlist)).toBe(false);
    });
    
    it('should allow IP in CIDR range', () => {
        const allowlist = ['192.168.1.0/24'];
        expect(isIpAllowed('192.168.1.1', allowlist)).toBe(true);
        expect(isIpAllowed('192.168.1.100', allowlist)).toBe(true);
        expect(isIpAllowed('192.168.1.254', allowlist)).toBe(true);
    });
    
    it('should deny IP outside CIDR range', () => {
        const allowlist = ['192.168.1.0/24'];
        expect(isIpAllowed('192.168.2.1', allowlist)).toBe(false);
        expect(isIpAllowed('10.0.0.1', allowlist)).toBe(false);
    });
    
    it('should handle IPv6 addresses', () => {
        const allowlist = ['::1', '2001:db8::/32'];
        expect(isIpAllowed('::1', allowlist)).toBe(true);
        expect(isIpAllowed('2001:db8::1', allowlist)).toBe(true);
    });
});
