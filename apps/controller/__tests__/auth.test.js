import { describe, it, expect, beforeAll } from '@jest/globals';
import { signToken, verifyToken } from '../auth/jwt.js';
import crypto from 'node:crypto';

// Mock JWT_SECRET for tests
process.env.JWT_SECRET = crypto.randomBytes(32).toString('hex');
process.env.JWT_EXPIRES_IN = '1h';

describe('JWT Authentication', () => {
    describe('signToken', () => {
        it('should create a valid JWT token', () => {
            const payload = { sub: 'user-123', role: 'user', disabled: false };
            const token = signToken(payload);
            
            expect(token).toBeTruthy();
            expect(typeof token).toBe('string');
            expect(token.split('.')).toHaveLength(3);
        });
        
        it('should include jti in token', () => {
            const payload = { sub: 'user-123', role: 'user' };
            const token = signToken(payload);
            
            const parts = token.split('.');
            const payloadDecoded = JSON.parse(Buffer.from(parts[1], 'base64').toString());
            
            expect(payloadDecoded.jti).toBeTruthy();
        });
    });
    
    describe('verifyToken', () => {
        it('should verify a valid token', async () => {
            const payload = { sub: 'user-456', role: 'admin', disabled: false };
            const token = signToken(payload);
            const verified = await verifyToken(token);
            
            expect(verified.sub).toBe('user-456');
            expect(verified.role).toBe('admin');
        });
        
        it('should reject disabled user token', async () => {
            const token = signToken({ sub: 'user-disabled', disabled: true });
            await expect(verifyToken(token)).rejects.toThrow('User is disabled');
        });
    });
});
