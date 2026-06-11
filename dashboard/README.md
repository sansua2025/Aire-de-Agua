This is a [Next.js](https://nextjs.org) project bootstrapped with [`create-next-app`](https://nextjs.org/docs/app/api-reference/cli/create-next-app).

## Getting Started

First, run the development server:

```bash
npm run dev
```

Open [http://localhost:3000](http://localhost:3000) with your browser to see the result.

## CI (GitHub Actions)

El workflow `.github/workflows/dashboard-ci.yml` corre en cada PR que toca `dashboard/**`:

1. `npm ci` (o `npm install` si el lock está desincronizado)
2. `npx tsc --noEmit` — type-check sin emitir
3. `npx eslint .` — lint

No requiere secrets — solo node 20 y las dependencias del proyecto.

## Vercel — ignoreCommand

`vercel.json` configura `ignoreCommand` para que Vercel (con Root Directory = `dashboard`)
solo lance un build cuando cambió algo dentro de `dashboard/`. Los PRs que solo
tocan `supabase/`, `n8n/` u otros directorios del repo raíz no generan un deploy.

```json
{ "ignoreCommand": "git diff --quiet HEAD^ HEAD -- ." }
```

Referencia: [Vercel ignoreCommand docs](https://vercel.com/docs/projects/overview#ignored-build-step).

## Tipos de Supabase

Los tipos en `types/database.ts` se generan con el CLI de Supabase contra el schema `public`:

```bash
npx supabase gen types typescript \
  --project-id vnctmzsgemefgbtjctlo \
  --schema public \
  > types/database.ts
```

Los tipos del schema `analytics` (views del dashboard) están en `types/analytics.ts`
y se mantienen **a mano** porque `gen types` solo emite un schema a la vez y las
views de analytics cambian con menor frecuencia. Actualizar `analytics.ts` cuando
se modifique una view en `supabase/migrations/`.

## Learn More

- [Next.js Documentation](https://nextjs.org/docs)
- [Supabase JS client](https://supabase.com/docs/reference/javascript)

## Deploy on Vercel

The easiest way to deploy this app is to use the [Vercel Platform](https://vercel.com/new).
Root Directory must be set to `dashboard`.
