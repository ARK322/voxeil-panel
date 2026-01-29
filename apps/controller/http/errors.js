export class HttpError extends Error {
    statusCode;
    details;
    constructor(statusCode, message, details = null) {
        super(message);
        this.statusCode = statusCode;
        this.details = details;
        this.name = "HttpError";
    }
    
    /**
     * Get sanitized error response for client
     * Hides sensitive details in production
     */
    toResponse(isProduction = false) {
        const response = {
            error: this.message,
            statusCode: this.statusCode
        };
        
        // Only include details in development
        if (!isProduction && this.details) {
            response.details = this.details;
        }
        
        return response;
    }
}

/**
 * Sanitize error message for production
 * Removes potentially sensitive information
 */
export function sanitizeErrorMessage(error, isProduction = false) {
    if (!isProduction) {
        return error.message || String(error);
    }
    
    // In production, use generic messages for common errors
    if (error.code === 'ECONNREFUSED') {
        return 'Service temporarily unavailable';
    }
    
    if (error.code === 'ETIMEDOUT') {
        return 'Request timeout';
    }
    
    if (error.name === 'ValidationError') {
        return 'Invalid input';
    }
    
    // Default generic message
    return 'Internal server error';
}
