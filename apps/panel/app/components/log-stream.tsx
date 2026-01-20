"use client";

import { useEffect, useRef, useState } from "react";

type LogStreamProps = {
  slug: string;
};

export function LogStream({ slug }: LogStreamProps) {
  const [lines, setLines] = useState<string[]>([]);
  const [status, setStatus] = useState<"idle" | "connecting" | "streaming" | "error">("idle");
  const [error, setError] = useState<string | null>(null);
  const readerRef = useRef<ReadableStreamDefaultReader<Uint8Array> | null>(null);
  const bufferRef = useRef<string>("");

  useEffect(() => {
    let cancelled = false;

    async function start() {
      setStatus("connecting");
      setError(null);
      setLines([]);
      try {
        const res = await fetch(`/api/logs?slug=${encodeURIComponent(slug)}`);
        if (!res.ok || !res.body) {
          const text = await res.text().catch(() => "");
          throw new Error(text || "Log stream error.");
        }
        setStatus("streaming");
        const reader = res.body.getReader();
        readerRef.current = reader;
        const decoder = new TextDecoder();
        while (!cancelled) {
          const { value, done } = await reader.read();
          if (done) break;
          const chunk = decoder.decode(value, { stream: true });
          bufferRef.current += chunk;
          const parts = bufferRef.current.split("\n");
          bufferRef.current = parts.pop() ?? "";
          if (parts.length > 0) {
            setLines((prev) => {
              const next = prev.concat(parts);
              return next.length > 2000 ? next.slice(-2000) : next;
            });
          }
        }
      } catch (err: any) {
        if (!cancelled) {
          setStatus("error");
          setError(err?.message ?? "Log stream error.");
        }
      }
    }

    void start();

    return () => {
      cancelled = true;
      readerRef.current?.cancel().catch(() => undefined);
    };
  }, [slug]);

  return (
    <div style={{ display: "grid", gap: 8 }}>
      <div style={{ display: "flex", gap: 12, alignItems: "center" }}>
        <strong>Status:</strong>
        <span>{status}</span>
        {error ? <span style={{ color: "crimson" }}>{error}</span> : null}
      </div>
      <pre
        style={{
          background: "#0f172a",
          color: "#e2e8f0",
          padding: 12,
          borderRadius: 8,
          minHeight: 160,
          maxHeight: 360,
          overflow: "auto",
          fontSize: 12,
          lineHeight: 1.4
        }}
      >
        {lines.length ? lines.join("\n") : "Waiting for logs..."}
      </pre>
    </div>
  );
}
