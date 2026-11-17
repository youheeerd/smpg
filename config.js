// Connects the game to your Supabase project. Both values are safe to publish:
// the database only answers through the locked-down functions in supabase/schema.sql.
// Find them in Supabase under Project Settings > API (or "API Keys").
window.SMPG_CONFIG = {
  url: "https://YOUR-PROJECT.supabase.co",
  key: "YOUR-PUBLISHABLE-KEY"
};
