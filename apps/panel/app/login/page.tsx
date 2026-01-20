import { redirect } from "next/navigation";
import { getSessionToken } from "../lib/session";
import { LoginForm } from "./login-form";

export default function LoginPage() {
  if (getSessionToken()) redirect("/");

  return (
    <main>
      <h1>Voxeil Panel</h1>
      <p>Enter the admin credentials configured by the installer.</p>
      <LoginForm />
    </main>
  );
}
