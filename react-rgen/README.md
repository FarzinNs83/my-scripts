# rgen

Project generator for React. One command sets up a complete Vite app, and
others add CRUD features, pages, forms, auth, models and components, so
neither you nor an AI assistant has to write the same boilerplate again.
Requires Python 3.9+ and Node.js.

Stack: Vite + React + TypeScript, Tailwind v4, shadcn/ui, React Router,
TanStack Query, axios, zustand, react-hook-form + zod, usehooks-ts, sonner,
MSW (a fake API, so the app runs before the backend exists), Vitest +
Testing Library, GitHub Actions.
Components: shadcn/ui, React Bits and the community registries the shadcn
CLI knows (Magic UI, Aceternity, Animate UI, Kibo UI, ...).

## Install

Go to the react-rgen folder and run:

```bash
pip install .
```

Or without installing: add `react-rgen/bin` to your `PATH`.

## Usage

```bash
rgen init my-app                     # new project (or run 'rgen init' inside an existing Vite project)
rgen auth                            # login / register pages, auth hooks, token refresh
rgen feature product --fields "name:string,price:number,status:enum(draft|live)"
rgen page settings --protected --nav # a page with a route
rgen form contact --fields "email:email,message:text"
rgen model User --file user.json     # zod schema + types from JSON
rgen ui calendar sheet               # shadcn/ui components
rgen bits SplitText Aurora           # React Bits animated components
rgen add @magicui/marquee            # any shadcn registry
rgen list                            # every command; 'rgen <command> --help' for options
```

Every command takes `-n` (preview, write nothing) and `-f` (overwrite
existing files). Existing files are never overwritten without `-f`. Files
rgen writes are formatted with the project's prettier.

## rgen init

```bash
rgen init my-app                     # new folder
rgen init my-app --rtl --i18n        # Persian first: RTL, Vazirmatn font, fa + en with a language switch
rgen init my-app --layout sidebar    # collapsible side menu (dashboards, admin panels) instead of a top bar
rgen init --pm pnpm --preset maia    # package manager, shadcn style preset
rgen init --no-mocks --no-tests --no-ci   # leave out the fake API, Vitest, the CI workflow
rgen init --no-install               # write the files only, print the install commands
```

It installs the packages, runs `shadcn init` and `msw init`, and adds the
common shadcn components. In an existing Vite project it replaces
`src/main.tsx` and tells you what to change by hand (tsconfig paths, the
starter's `App.tsx`).

| Path | What |
| --- | --- |
| `src/lib/api-client.ts` | axios with the auth header, one shared token refresh on 401, and errors turned into `ApiError` |
| `src/lib/api-error.ts` | `ApiError` (status, data, `fieldErrors` for 422), `getErrorMessage()` |
| `src/lib/query-client.ts` | TanStack Query: no retry on 4xx, an error toast for failed mutations (`meta: { silent: true }` turns it off) |
| `src/lib/env.ts` | zod-validated `VITE_*` variables; the app fails at startup if one is missing |
| `src/stores/auth-store.ts` | tokens and user (zustand, kept in localStorage) |
| `src/app/router.tsx` | lazy routes in three groups: with the layout, signed-in only, and without the layout |
| `src/app/paths.ts` | every route path, plus `href(paths.x, { id })` |
| `src/app/nav.ts` | header links |
| `src/components/layout/app-layout.tsx` | header with nav, theme switch, sign out |
| `src/components/common/` | `PageLoader`, `EmptyState`, `ErrorState`, `RouteError`, `NotFound`, `ProtectedRoute` |
| `src/components/theme-provider.tsx` | light / dark / system, also used by the toasts |
| `src/lib/i18n.ts`, `src/locales/` | with `--i18n`: i18next, and `<html dir>` follows the language |
| `src/mocks/` | the fake API: `handlers.ts` collects every feature's handlers, `createTable()` is an in-memory table |
| `.env.development` | `VITE_MOCK_API=true`: `npm run dev` uses the fake API; set `false` for the real one |
| `src/test/` | Vitest setup, `renderWithProviders()` and the MSW server for tests |
| `.github/workflows/ci.yml` | lint, typecheck, tests and build on every push |
| `.vscode/extensions.json` | ESLint, Prettier, Tailwind and Vitest extensions |
| `AGENTS.md`, `CLAUDE.md` | instructions telling AI assistants to use rgen (see below) |
| `.rgen/config.json` | the init choices |

## rgen feature

```bash
rgen feature product --fields "name:string,price:number,stock:int,active:bool,status:enum(draft|live),notes:text?"
rgen feature order,invoice           # several at once (default field: name)
rgen feature product --paginated     # server-side search + pagination, kept in the URL (?q=&page=)
rgen feature product --protected     # the pages need a signed-in user
rgen feature product --no-detail     # no detail page
rgen feature product --no-ui         # only types, api, hooks and the fake API
rgen feature product --endpoint /v2/items
```

It writes `src/features/product/`:

| File | What |
| --- | --- |
| `types.ts` | `productSchema`, `Product`, `productInputSchema`, `ProductInput` |
| `api.ts` | `productApi.list / get / create / update / remove` on `/products` |
| `hooks.ts` | `productKeys`, `useProducts`, `useProduct`, `useCreateProduct`, `useUpdateProduct`, `useDeleteProduct` |
| `components/product-table.tsx` | shadcn table with edit / delete buttons |
| `components/product-form.tsx` | zod + react-hook-form, the right input for each field type |
| `pages/product-list-page.tsx` | loading / error / empty states, create and edit dialog, delete confirmation |
| `pages/product-detail-page.tsx` | one product at `/products/:id`; the first column of the table links to it |
| `mocks.ts` | fake API with sample rows (25 with `--paginated`), registered in `src/mocks/handlers.ts` |
| `pages/product-list-page.test.tsx` | Vitest: the list shows the API data, the form validates |

It also adds the routes, `paths.products` / `paths.productDetail` and a
nav link, and installs the shadcn components the code uses.

With `--paginated`, `list()` sends `?page=&pageSize=&q=` and expects
`{ items, total, page, pageSize }` (change `Paginated<T>` in
`src/types/api.ts` if your API names them differently).

Field types: `string`, `text`, `number`, `int`, `bool`, `date`, `email`,
`url`, `password`, `enum(a|b|c)`. Add `?` for optional (`notes:text?`).

## Other generators

```bash
rgen page product-detail --in product --path /products/:id   # reads :id with useParams
rgen page login-help --bare                                   # without the header layout
rgen form checkout --fields "address:text,plan:enum(free|pro),terms:bool" --in cart
rgen model Order --file order.json --in order                # nested objects become their own schemas
curl -s https://api.example.com/users/1 | rgen model User    # JSON from stdin
rgen store cart --persist                                     # zustand store in localStorage
rgen hook use-countdown
rgen component price-tag --in product
rgen env STRIPE_KEY --default ""                              # typed in env.ts, added to .env.example
rgen openapi https://api.example.com/openapi.json            # orval: typed functions + query hooks on apiClient
```

Forms show server-side validation errors next to their fields when the API
answers 422 with `{ "errors": { "email": ["taken"] } }`.

## Fake API, tests and deploy

`npm run dev` answers API calls from `src/mocks` while `VITE_MOCK_API=true`
in `.env.development`, so pages work before the backend exists. `rgen auth`
adds a fake login (any email, password `password`; registering
`taken@example.com` shows a 422). Requests without a handler go to the real
API. Production builds never use the mocks.

```bash
npm run test                         # Vitest in watch mode (npm run test:run once)
rgen docker                          # Dockerfile (node build -> nginx) + nginx.conf with SPA routing
```

Tests render with `renderWithProviders()` from `src/test/render.tsx` and
use the same fake API; override one endpoint in a test with
`server.use(http.get(...))`.

## Components

```bash
rgen ui --list                       # shadcn components and blocks
rgen ui calendar sheet drawer
rgen ui login-03 dashboard-01        # whole blocks
rgen bits --list                     # React Bits: text, animations, components, backgrounds
rgen bits split-text aurora          # into src/components/bits/
rgen add @magicui/marquee @aceternity/3d-card-effect @animate-ui/...
```

Preview them at [ui.shadcn.com](https://ui.shadcn.com), [reactbits.dev](https://reactbits.dev),
[magicui.design](https://magicui.design) and [ui.aceternity.com](https://ui.aceternity.com).

## With AI assistants

`rgen init` writes an rgen section into `AGENTS.md` (Codex, Cursor and
others read it), and `CLAUDE.md` imports it for Claude Code. It tells the
assistant to run rgen for structure and to write only the real logic, and
lists the conventions: feature folders, `apiClient`, query hooks, `paths`,
usehooks-ts before custom hooks, shadcn and React Bits before custom
components. The assistant can read `rgen list --json` to see every command,
field type and component.

```bash
rgen ai                              # add or refresh that section in an existing project
```

## Custom templates

```bash
rgen eject                           # copy the templates to .rgen/templates
```

Edit the copies; rgen uses them instead of the built-in ones. The syntax is
`{{ expression }}` and `{% if %}` / `{% else %}` / `{% endif %}` (the same
engine as fgen). Keep the `// rgen:...` marker comments in `paths.ts`,
`router.tsx`, `nav.ts`, `env.ts` and `src/mocks/handlers.ts`; rgen inserts
lines above them.

## Tests

```bash
python -m unittest discover -s tests
```
