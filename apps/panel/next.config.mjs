import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/** @type {import('next').NextConfig} */
const nextConfig = {
  transpilePackages: ['@voxeil/shared', '@voxeil/api-client'],
  webpack: (config) => {
    config.resolve.alias = {
      ...config.resolve.alias,
      '@voxeil/shared': path.resolve(__dirname, '../../packages/shared'),
      '@voxeil/api-client': path.resolve(__dirname, '../../packages/api-client'),
    };
    return config;
  },
};

export default nextConfig;
