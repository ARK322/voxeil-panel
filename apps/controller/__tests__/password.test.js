import { describe, it, expect } from '@jest/globals';
import crypto from 'node:crypto';
import { promisify } from 'node:util';

const scryptAsync = promisify(crypto.scrypt);

async function hashPassword(password) {
    const salt = crypto.randomBytes(16).toString("hex");
    const hash = await scryptAsync(password, salt, 64);
    return `${salt}:${hash.toString("hex")}`;
}

async function verifyPassword(password, stored) {
    const [salt, hashHex] = stored.split(":");
    if (!salt || !hashHex) {
        return false;
    }
    const hash = await scryptAsync(password, salt, 64);
    return crypto.timingSafeEqual(Buffer.from(hashHex, "hex"), hash);
}

describe('Password Hashing', () => {
    it('should hash password securely', async () => {
        const password = 'Test123!@#';
        const hash = await hashPassword(password);
        
        expect(hash).toContain(':');
        expect(hash.split(':')[0]).toHaveLength(32);
        expect(hash.split(':')[1]).toHaveLength(128);
    });
    
    it('should verify correct password', async () => {
        const password = 'SecurePass123!';
        const hash = await hashPassword(password);
        expect(await verifyPassword(password, hash)).toBe(true);
    });
    
    it('should reject incorrect password', async () => {
        const password = 'CorrectPassword123!';
        const hash = await hashPassword(password);
        expect(await verifyPassword('WrongPassword123!', hash)).toBe(false);
    });
    
    it('should produce different hashes for same password', async () => {
        const password = 'SamePassword123!';
        const hash1 = await hashPassword(password);
        const hash2 = await hashPassword(password);
        
        expect(hash1).not.toBe(hash2);
        expect(await verifyPassword(password, hash1)).toBe(true);
        expect(await verifyPassword(password, hash2)).toBe(true);
    });
});
