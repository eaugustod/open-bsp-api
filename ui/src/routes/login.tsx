import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { supabase } from "@/supabase/client";
import { useTranslation } from "@/hooks/useTranslation";
import { GoogleOutlined, GithubOutlined } from "@ant-design/icons";

type OAuthProvider = "google" | "github";

export const Route = createFileRoute("/login")({
  validateSearch: (search): { redirect?: string; email?: string } => ({
    redirect: (search.redirect as string) || undefined,
    email: (search.email as string) || undefined,
  }),
  component: Login,
});

function Login() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [message, setMessage] = useState("");
  const [loading, setLoading] = useState(false);
  const [isSignUp, setIsSignUp] = useState(false);
  const { redirect } = Route.useSearch();

  const { translate: t } = useTranslation();

  async function handleLogInWithOauth(provider: OAuthProvider) {
    try {
      setMessage("");
      const { error } = await supabase.auth.signInWithOAuth({
        provider,
        options: {
          redirectTo: window.location.origin + (redirect || "/"),
        },
      });
      if (error) {
        setMessage(error.message);
      }
    } catch (err: any) {
      setMessage(err?.message || "Erro ao conectar com provedor OAuth");
    }
  }

  async function handleEmailAuth(e?: React.FormEvent) {
    if (e) e.preventDefault();
    setMessage("");
    setLoading(true);

    try {
      if (isSignUp) {
        const { data, error } = await supabase.auth.signUp({
          email,
          password,
        });

        if (error) {
          setMessage(error.message);
        } else if (data.session) {
          setEmail("");
          setPassword("");
        } else {
          setMessage(t("Conta criada com sucesso! Se necessário, confirme pelo email."));
        }
      } else {
        const { error } = await supabase.auth.signInWithPassword({
          email,
          password,
        });

        if (error) {
          setMessage(t("¡Credenciales inválidas!"));
        } else {
          setEmail("");
          setPassword("");
        }
      }
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="flex flex-col gap-8 justify-center items-center bg-background text-foreground h-dvh w-screen px-4">
      <div className="text-primary tracking-tighter font-bold text-[36px]">
        OpenBSP
      </div>

      <div className="flex flex-col gap-4 w-full max-w-[320px]">
        <form onSubmit={handleEmailAuth} className="login-form flex flex-col gap-3">
          <label>
            <div className="label">{t("Correo electrónico")}</div>
            <input
              className="text"
              placeholder="seu@email.com"
              type="email"
              required
              onChange={(e) => setEmail(e.target.value)}
              value={email}
            />
          </label>

          <label>
            <div className="label">{t("Contraseña")}</div>
            <input
              className="text"
              placeholder="******"
              type="password"
              required
              onChange={(e) => setPassword(e.target.value)}
              value={password}
            />
          </label>

          {message && (
            <div className="text-destructive text-sm text-center font-medium">
              {message}
            </div>
          )}

          <button
            type="submit"
            disabled={loading}
            className="primary w-full mt-2 cursor-pointer"
          >
            {loading ? "..." : isSignUp ? t("Crear cuenta") : t("Entrar")}
          </button>

          <div className="text-center text-xs text-muted-foreground mt-1">
            <button
              type="button"
              className="hover:underline text-primary cursor-pointer bg-transparent border-none p-0"
              onClick={() => {
                setIsSignUp(!isSignUp);
                setMessage("");
              }}
            >
              {isSignUp
                ? "¿Ya tienes cuenta? Iniciar sesión"
                : "¿No tienes cuenta? Regístrate"}
            </button>
          </div>
        </form>

        <div className="flex items-center gap-3 my-1">
          <div className="border-b border-border flex-1" />
          <span className="text-xs text-muted-foreground uppercase">o</span>
          <div className="border-b border-border flex-1" />
        </div>

        <button
          type="button"
          className="primary bg-blue-500 hover:bg-blue-400 text-white w-full border-none cursor-pointer flex items-center justify-center gap-2"
          onClick={() => handleLogInWithOauth("google")}
        >
          <GoogleOutlined /> {t("Continuar con Google")}
        </button>

        <button
          type="button"
          className="primary bg-gray-900 hover:bg-gray-800 text-white w-full border-none cursor-pointer flex items-center justify-center gap-2"
          onClick={() => handleLogInWithOauth("github")}
        >
          <GithubOutlined /> {t("Continuar con GitHub")}
        </button>
      </div>
    </div>
  );
}
