import LoginForm from "./LoginForm";

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string }>;
}) {
  const { next } = await searchParams;
  // Only allow internal redirect targets.
  const safeNext = next && next.startsWith("/") ? next : "/browse";
  return <LoginForm next={safeNext} />;
}
