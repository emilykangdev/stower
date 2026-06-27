
This creates policies for testing the codebase in the real hosted Keygen. 

```
npx @dotenvx/dotenvx run -f Scripts/Keygen/remote-testing/.env -- \
  deno run --allow-env --allow-net=api.keygen.sh \
  Scripts/Keygen/remote-testing/create-policies.ts
```
