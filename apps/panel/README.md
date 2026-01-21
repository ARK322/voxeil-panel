# Voxeil Panel

Modern cPanel-like hosting control panel built with Next.js App Router.

## Features

- **Dashboard**: Overview of tenants, sites, mail, databases, DNS, and backups
- **User Management**: View and manage tenants/users with their namespaces
- **Web Sites**: Create and manage web applications with domains, TLS, and deployments
- **Mail**: Manage email domains and mailboxes (integrates with mailcow)
- **Database**: PostgreSQL database management (integrates with pgAdmin)
- **DNS**: DNS zone and record management
- **Backups**: Backup snapshot management and scheduling
- **Health**: Platform component health monitoring

## Running Locally

1. **Install dependencies**:
   ```bash
   npm install
   # or
   pnpm install
   # or
   yarn install
   ```

2. **Set up environment variables** (optional):
   ```bash
   cp .env.example .env.local
   # Edit .env.local with your settings
   ```

3. **Run the development server**:
   ```bash
   npm run dev
   # or
   pnpm dev
   # or
   yarn dev
   ```

4. **Open your browser**:
   Navigate to [http://localhost:3000/panel](http://localhost:3000/panel)

## Project Structure

```
apps/panel/
├── app/
│   ├── api/              # Next.js API route handlers (mock data)
│   ├── panel/            # Panel pages (dashboard, users, web, etc.)
│   └── globals.css       # Global styles with Tailwind
├── src/
│   └── lib/
│       ├── api.ts        # Typed API client
│       ├── types.ts      # Shared TypeScript types
│       └── env.ts        # Environment variable validation
├── mock-data/            # JSON mock data files
└── package.json
```

## API Routes

All API routes are under `/api` and return mock data. In production, these should be wired to the actual controller API.

- `GET /api/health` - System health status
- `GET /api/tenants` - List all tenants
- `GET /api/tenants/:id` - Get tenant details
- `GET /api/sites` - List all sites
- `GET /api/sites/:id` - Get site details
- `POST /api/sites` - Create a new site (mock)
- `POST /api/sites/:id/deploy` - Deploy a site (mock)
- `GET /api/mail` - Mail configuration
- `GET /api/db` - Database configuration
- `GET /api/dns` - DNS configuration
- `GET /api/backups` - Backup information

## TODOs

- Wire API routes to real controller endpoints
- Add authentication (JWT-based)
- Implement real CRUD operations
- Add search/filter functionality
- Add loading states and error boundaries
- Add form validation
