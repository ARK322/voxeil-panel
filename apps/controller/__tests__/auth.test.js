import { describe, it, expect, jest } from '@jest/globals';

// Mock token revocation service before importing jwt.js
// This must be done before any imports that use the token revocation service
jest.unstable_mockModule('../auth/token-revocation.service.js', () => ({
    isTokenRevoked: jest.fn().mockResolvedValue(false),
    revokeTokenJti: jest.fn().mockResolvedValue(undefined),
    pruneExpiredRevocations: jest.fn().mockResolvedValue(0),
}));

// JWT_SECRET is set in jest.setup.js before any modules are loaded
// Import jwt.js after setting up the mock
const { signToken, verifyToken } = await import('../auth/jwt.js');

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
