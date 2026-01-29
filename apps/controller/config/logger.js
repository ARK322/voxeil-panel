import pino from "pino";

const isProduction = process.env.NODE_ENV === "production";

export const logger = pino({
    level: process.env.LOG_LEVEL || (isProduction ? "info" : "debug"),
    formatters: {
        level: (label) => ({ level: label }),
    },
    serializers: {
        err: pino.stdSerializers.err,
        req: (req) => ({
            id: req.id,
            method: req.method,
            url: req.url,
            ip: req.ip,
        }),
        res: (res) => ({
            statusCode: res.statusCode,
        }),
    },
    timestamp: pino.stdTimeFunctions.isoTime,
});
