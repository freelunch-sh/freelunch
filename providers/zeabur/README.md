# Zeabur

| | |
|---|---|
| **Status** | 🚧 Planned: researched, **not implemented** (the API can't be pinned from public sources) |
| **Layer** | `platform` |
| **Terraform provider** | None. The API is GraphQL |
| **Last verified** | 2026-11-08 |

The free plan deploys to your own server, not a shared cluster; services sleep when idle.
See `provider.yaml` for the free-tier facts.

## What is known (2026-11-08)

Read from Zeabur's docs and from the source of its CLI (`github.com/zeabur/cli`, `pkg/api`):

- Endpoint `https://api.zeabur.com/graphql`, `Authorization: Bearer <API key>`. Keys are made at
  Dashboard > Settings > API Keys and belong to a personal account. No environment variable name
  is documented.
- Verify a token: `query { me { _id username } }`.
- List projects: `projects(skip, limit)` as a connection (`pageInfo { hasNextPage }`, `edges { node }`),
  at most 100 a page. Create: `createProject(region, name)`. Delete: `deleteProject(_id)` and
  `deleteService(_id)`, both returning a Boolean. Regions come from `regions { id name available }`.
- A service from a Docker image: `createPrebuiltService(projectID, schema: ServiceSpecSchemaInput)`
  with `source { image }`, `ports [{ id, port, type }]` (type `HTTP` or `TCP`) and `env [{ key, default }]`.
  An HTTP port gets a `*.zeabur.app` domain: `addDomain(serviceID, environmentID, isGenerated, domain)`.
- Status: `service(_id) { status(environmentID) }` and `deployments(serviceID, environmentID)`.

## What blocks it

None of these is documented anywhere that could be read, and an `api.yaml` needs each:

1. **The schema.** It is only browsable in the Apollo Explorer behind a login (the page came back
   empty), and the endpoint answered a plain GET with 400, so no introspection was possible.
   The GraphQL **variable types** are therefore unknown.
2. **The status values** of a service or deployment (which mean running, building, failed).
3. **The environment ID** that status and domains need, and how to look it up.
4. **Deleting what is already gone**: the error is not documented, and the delete mutations return
   a Boolean.
5. **Whether `createPrebuiltService` starts a deploy**, and how a **private registry's** credentials
   are given.
6. **An ownership marker.** A service has no labels, and `createProject` takes only a region and a
   name, so the only way to mark a project as freelunch's is its name.

## How to unblock it

With a key of your own, one introspection query answers 1 and shows the rest:

```bash
curl -s https://api.zeabur.com/graphql -H "Authorization: Bearer $ZEABUR_API_KEY" -H 'Content-Type: application/json' \
  -d '{"query":"{ __schema { mutationType { fields { name args { name type { kind name ofType { name } } } } } queryType { fields { name args { name type { kind name ofType { name } } } } } } }"}' > zeabur-schema.json
```

Give freelunch that file (it holds no secret) and the calls can be pinned and tested against a
fixture. A live account is still what makes `verified: live`.
