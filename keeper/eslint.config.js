// @ts-check
import js from "@eslint/js";
import tseslint from "typescript-eslint";
import prettier from "eslint-config-prettier";

export default tseslint.config(
  { ignores: ["dist/**", "node_modules/**", "src/abi/generated.ts", "state/**"] },
  js.configs.recommended,
  {
    // Type-aware linting applies to the TypeScript sources only. Scoping it by `files` rather than
    // switching it off again per-file keeps the plain-JS config and the ABI generator out of the
    // type-checked program entirely, which is the only arrangement that does not need a second
    // "and now undo that" block.
    files: ["src/**/*.ts", "test/**/*.ts"],
    extends: [...tseslint.configs.recommendedTypeChecked],
    languageOptions: {
      // tsconfig.json covers src only; tsconfig.test.json adds test/ so lint sees everything.
      parserOptions: { project: ["./tsconfig.test.json"], tsconfigRootDir: import.meta.dirname },
    },
    rules: {
      "@typescript-eslint/no-floating-promises": "error",
      "@typescript-eslint/no-misused-promises": "error",
      "@typescript-eslint/consistent-type-imports": "error",
      "no-console": "warn",
    },
  },
  {
    // node:test's describe/it return promises the runner owns; awaiting them is wrong, not right.
    files: ["test/**/*.ts"],
    rules: { "@typescript-eslint/no-floating-promises": "off" },
  },
  {
    files: ["scripts/**/*.mjs"],
    languageOptions: { globals: { console: "readonly", process: "readonly" } },
    rules: { "no-console": "off" },
  },
  prettier,
);
