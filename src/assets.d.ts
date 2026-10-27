// esbuild --loader:.ps1=text: the helper script is bundled into dist/index.js as a string
declare module "*.ps1" {
  const text: string;
  export default text;
}
