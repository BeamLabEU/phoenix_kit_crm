defmodule PhoenixKitCRM.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_crm` — the
  decentralized-migrations protocol core's `mix phoenix_kit.update`
  discovers via `migration_module/0`: `current_version/0` +
  `migrated_version_runtime/1` + idempotent `up/1` + version-aware
  `down/1`. `phoenix_kit_projects` is the reference implementation;
  `PhoenixKit.Modules.Legal.Migrations` is the closest precedent — this
  chain is the same shape, scaled up to ten adopted tables instead of one.

  ## What V01 is

  V01 is an ADOPTION step for all ten `phoenix_kit_crm_*` tables, not a
  create:

    * on existing installs every table is already there (core's V135 /
      V138 / V148 / V151 / V152), the `CREATE TABLE IF NOT EXISTS` /
      `ADD COLUMN IF NOT EXISTS` / guarded `DO $$ ... pg_constraint ...
      $$` blocks all find their targets already in place, and the only
      genuinely new objects are `phoenix_kit_crm_companies.user_uuid`
      (nullable FK → `phoenix_kit_users`, `ON DELETE SET NULL`), its
      partial unique index `idx_crm_companies_user_uuid`, and the
      `crm_schema:1` marker — from then on this chain owns every
      adopted table's future shape;
    * on a hypothetical fresh install whose core baseline no longer
      creates these tables, the same statements create them —
      shape-identical to core's current live DDL, with core's exact
      table/constraint/index names (verified against
      `lib/phoenix_kit/migrations/postgres/v135.ex`, `v138.ex`,
      `v148.ex`, `v151.ex`, `v152.ex` in core).

  Because V01 changes no shape of the nine adopted tables, core's
  `ExpectedSchema` manifest (which still audits those tables' shapes)
  stays accurate and no core release is required for this version. The
  first version that changes shape (V2+) must follow the excluded-object
  protocol described in the Legal chain's extraction report before it
  ships.

  ## What `down/1` is NOT

  `down/1` unstamps the version marker; it NEVER drops any of the ten
  tables. Nine are adopted (core-created on most installs; CRM data —
  contacts, companies, interactions — is not this chain's to destroy),
  and the tenth (`phoenix_kit_crm_companies.user_uuid`) is a link column
  a rollback should not delete either — the mirror it points at is a
  live user record. The ownership test pins this by asserting no
  statement this module can emit matches `DROP` or `TRUNCATE`.

  The migrated version is tracked as a `crm_schema:<N>` `COMMENT ON
  TABLE` marker on `phoenix_kit_crm_contacts` (the marker convention
  from the projects/Legal chains). A marker-less table reads as version
  0 — the core-baseline shape before this chain existed.
  """

  use Ecto.Migration

  @current_version 1
  @marker_prefix "crm_schema:"
  @version_table "phoenix_kit_crm_contacts"

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `crm_schema:<N>` marker (auditor contract)."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc """
  The chain version currently applied in the database, read OUTSIDE a
  migration (the protocol shape core's update task calls — `opts` with
  `:prefix`): the `crm_schema:<N>` marker when present; a marker-less or
  foreign-comment table reads as `0` (core-baseline shape — V1 is purely
  adoptive, there is no pre-chain content to defend).
  """
  def migrated_version_runtime(opts \\ []) do
    prefix = validated_prefix(opts)

    # classoid anchors the description join to pg_class (the projects
    # chain's convention, via Legal/document_creator).
    query = """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = '#{@version_table}' AND c.relkind = 'r'
    """

    case PhoenixKit.RepoHelper.repo().query(query, [prefix]) do
      {:ok, %{rows: [[@marker_prefix <> n]]}} -> parse_version(n)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  @doc "Applies every chain version up to `current_version/0` (idempotent)."
  def up(opts \\ []) do
    opts
    |> validated_prefix()
    |> up_statements()
    |> Enum.each(&execute/1)
  end

  @doc "Rolls back to `target` (`:version` in `opts`). Never drops a table — see the moduledoc."
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    target = if is_list(opts), do: Keyword.get(opts, :version, 0), else: 0

    prefix
    |> down_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. Every
  statement is idempotent (`IF NOT EXISTS` / guarded `DO $$` block /
  `COMMENT`) so it is safe to replay on an install where core already
  created some or all of these tables, and on a fresh install with
  none of them.
  """
  @spec up_statements(String.t()) :: [String.t()]
  def up_statements(prefix \\ "public") do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    List.flatten([
      "CREATE EXTENSION IF NOT EXISTS citext",
      role_settings_statements(prefix, p),
      user_role_view_statements(prefix, p),
      contacts_statements(p),
      companies_statements(p),
      company_memberships_statements(p),
      interactions_statements(p),
      interaction_parties_statements(p),
      party_roles_statements(prefix, p),
      lists_statements(p),
      list_members_statements(p),
      "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{@current_version}'"
    ])
  end

  @doc "The SQL `down/1` executes, as data (marker bookkeeping only)."
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0) do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    if target > 0 do
      ["COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"]
    else
      ["COMMENT ON TABLE #{p}#{@version_table} IS NULL"]
    end
  end

  # ── role_settings (core V135) ────────────────────────────────────────

  defp role_settings_statements(prefix, p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_role_settings (
        role_uuid uuid NOT NULL,
        enabled boolean DEFAULT false NOT NULL,
        inserted_at timestamptz DEFAULT now() NOT NULL,
        updated_at timestamptz DEFAULT now() NOT NULL
      )
      """,
      guarded_constraint(
        prefix,
        "phoenix_kit_crm_role_settings",
        "phoenix_kit_crm_role_settings_pkey",
        "ALTER TABLE #{p}phoenix_kit_crm_role_settings ADD CONSTRAINT phoenix_kit_crm_role_settings_pkey PRIMARY KEY (role_uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_crm_role_settings",
        "phoenix_kit_crm_role_settings_role_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_crm_role_settings ADD CONSTRAINT phoenix_kit_crm_role_settings_role_uuid_fkey FOREIGN KEY (role_uuid) REFERENCES #{p}phoenix_kit_user_roles(uuid) ON DELETE CASCADE"
      )
    ]
  end

  # ── user_role_view (core V135) ───────────────────────────────────────

  defp user_role_view_statements(prefix, p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_user_role_view (
        uuid uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        user_uuid uuid NOT NULL,
        scope varchar(100) NOT NULL,
        view_config jsonb DEFAULT '{}'::jsonb NOT NULL,
        inserted_at timestamptz DEFAULT now() NOT NULL,
        updated_at timestamptz DEFAULT now() NOT NULL
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_crm_user_role_view_user ON #{p}phoenix_kit_crm_user_role_view USING btree (user_uuid)",
      guarded_constraint(
        prefix,
        "phoenix_kit_crm_user_role_view",
        "phoenix_kit_crm_user_role_view_pkey",
        "ALTER TABLE #{p}phoenix_kit_crm_user_role_view ADD CONSTRAINT phoenix_kit_crm_user_role_view_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_crm_user_role_view",
        "phoenix_kit_crm_user_role_view_user_scope_uniq",
        "ALTER TABLE #{p}phoenix_kit_crm_user_role_view ADD CONSTRAINT phoenix_kit_crm_user_role_view_user_scope_uniq UNIQUE (user_uuid, scope)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_crm_user_role_view",
        "phoenix_kit_crm_user_role_view_user_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_crm_user_role_view ADD CONSTRAINT phoenix_kit_crm_user_role_view_user_uuid_fkey FOREIGN KEY (user_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE"
      )
    ]
  end

  # ── contacts (core V138 + V151 citext email + V152 locale/opted_out_at/consent) ──
  # The version-marker table.

  defp contacts_statements(p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_contacts (
        uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
        name VARCHAR(255),
        status VARCHAR(50) NOT NULL DEFAULT 'active',
        email CITEXT,
        phone VARCHAR(50),
        notes TEXT,
        user_uuid UUID REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
        metadata JSONB NOT NULL DEFAULT '{}',
        inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        locale VARCHAR(10),
        opted_out_at TIMESTAMPTZ,
        consent JSONB NOT NULL DEFAULT '{}'
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_crm_contacts_user_uuid ON #{p}phoenix_kit_crm_contacts (user_uuid) WHERE user_uuid IS NOT NULL",
      "CREATE INDEX IF NOT EXISTS idx_crm_contacts_status ON #{p}phoenix_kit_crm_contacts (status)"
    ]
  end

  # ── companies (core V138 + V151 citext email) + NEW user_uuid ───────

  defp companies_statements(p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_companies (
        uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
        name VARCHAR(255),
        status VARCHAR(50) NOT NULL DEFAULT 'active',
        website VARCHAR(255),
        email CITEXT,
        phone VARCHAR(50),
        address TEXT,
        industry VARCHAR(255),
        notes TEXT,
        metadata JSONB NOT NULL DEFAULT '{}',
        inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_crm_companies_status ON #{p}phoenix_kit_crm_companies (status)",
      # *** NEW (this migration) — the one genuinely new object pair ***
      "ALTER TABLE #{p}phoenix_kit_crm_companies ADD COLUMN IF NOT EXISTS user_uuid UUID REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL",
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_crm_companies_user_uuid ON #{p}phoenix_kit_crm_companies (user_uuid) WHERE user_uuid IS NOT NULL"
    ]
  end

  # ── company_memberships (core V138) ─────────────────────────────────

  defp company_memberships_statements(p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_company_memberships (
        uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
        contact_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_crm_contacts(uuid) ON DELETE CASCADE,
        company_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_crm_companies(uuid) ON DELETE CASCADE,
        role_in_company VARCHAR(255),
        department VARCHAR(255),
        is_primary BOOLEAN NOT NULL DEFAULT false,
        position INTEGER NOT NULL DEFAULT 0,
        inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        CONSTRAINT phoenix_kit_crm_company_memberships_uniq UNIQUE (contact_uuid, company_uuid)
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_crm_memberships_contact ON #{p}phoenix_kit_crm_company_memberships (contact_uuid)",
      "CREATE INDEX IF NOT EXISTS idx_crm_memberships_company ON #{p}phoenix_kit_crm_company_memberships (company_uuid)"
    ]
  end

  # ── interactions (core V138) ────────────────────────────────────────

  defp interactions_statements(p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_interactions (
        uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
        contact_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_crm_contacts(uuid) ON DELETE CASCADE,
        interaction_type VARCHAR(50) NOT NULL DEFAULT 'note',
        occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        subject VARCHAR(255),
        body TEXT,
        owner_user_uuid UUID REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
        metadata JSONB NOT NULL DEFAULT '{}',
        inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_crm_interactions_contact ON #{p}phoenix_kit_crm_interactions (contact_uuid, occurred_at DESC)"
    ]
  end

  # ── interaction_parties (core V138) — staff_person_uuid deliberately no FK ──

  defp interaction_parties_statements(p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_interaction_parties (
        uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
        interaction_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_crm_interactions(uuid) ON DELETE CASCADE,
        raw_name VARCHAR(255) NOT NULL,
        contact_uuid UUID REFERENCES #{p}phoenix_kit_crm_contacts(uuid) ON DELETE SET NULL,
        staff_person_uuid UUID,
        party_snapshot JSONB NOT NULL DEFAULT '{}',
        position INTEGER NOT NULL DEFAULT 0,
        inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        CONSTRAINT phoenix_kit_crm_party_exclusive_arc
          CHECK (NOT (contact_uuid IS NOT NULL AND staff_person_uuid IS NOT NULL))
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_crm_parties_interaction ON #{p}phoenix_kit_crm_interaction_parties (interaction_uuid)",
      "CREATE INDEX IF NOT EXISTS idx_crm_parties_contact ON #{p}phoenix_kit_crm_interaction_parties (contact_uuid) WHERE contact_uuid IS NOT NULL",
      "CREATE INDEX IF NOT EXISTS idx_crm_parties_staff_person ON #{p}phoenix_kit_crm_interaction_parties (staff_person_uuid) WHERE staff_person_uuid IS NOT NULL"
    ]
  end

  # ── party_roles (core V148) — polymorphic, roleable_uuid deliberately no FK ──

  defp party_roles_statements(_prefix, p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_party_roles (
        uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
        roleable_type VARCHAR(20) NOT NULL,
        roleable_uuid UUID NOT NULL,
        role VARCHAR(30) NOT NULL,
        is_active BOOLEAN NOT NULL DEFAULT TRUE,
        valid_from DATE,
        valid_to DATE,
        metadata JSONB NOT NULL DEFAULT '{}',
        inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conname = 'phoenix_kit_crm_party_roles_roleable_type_check'
          AND conrelid = '#{p}phoenix_kit_crm_party_roles'::regclass
        ) THEN
          ALTER TABLE #{p}phoenix_kit_crm_party_roles
          ADD CONSTRAINT phoenix_kit_crm_party_roles_roleable_type_check
          CHECK (roleable_type IN ('company', 'contact'));
        END IF;
      END $$;
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_crm_party_roles_uniq ON #{p}phoenix_kit_crm_party_roles (roleable_type, roleable_uuid, role)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_crm_party_roles_role_active_idx ON #{p}phoenix_kit_crm_party_roles (role, is_active)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_crm_party_roles_roleable_idx ON #{p}phoenix_kit_crm_party_roles (roleable_type, roleable_uuid)"
    ]
  end

  # ── lists (core V152) ────────────────────────────────────────────────

  defp lists_statements(p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_lists (
        uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
        name VARCHAR(255) NOT NULL,
        slug VARCHAR(255) NOT NULL,
        description TEXT,
        status VARCHAR(20) NOT NULL DEFAULT 'active'
          CHECK (status IN ('active', 'archived')),
        subscribable BOOLEAN NOT NULL DEFAULT FALSE,
        subscriber_count INTEGER NOT NULL DEFAULT 0,
        locale VARCHAR(10),
        metadata JSONB NOT NULL DEFAULT '{}',
        inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_crm_lists_slug ON #{p}phoenix_kit_crm_lists (slug)"
    ]
  end

  # ── list_members (core V152) — needs citext ─────────────────────────

  defp list_members_statements(p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_crm_list_members (
        uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
        list_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_crm_lists(uuid) ON DELETE CASCADE,
        contact_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_crm_contacts(uuid) ON DELETE CASCADE,
        email CITEXT,
        status VARCHAR(20) NOT NULL DEFAULT 'subscribed'
          CHECK (status IN ('subscribed', 'pending', 'removed')),
        subscribed_at TIMESTAMPTZ,
        unsubscribed_at TIMESTAMPTZ,
        source VARCHAR(20) NOT NULL DEFAULT 'manual'
          CHECK (source IN ('manual', 'import', 'form', 'api')),
        metadata JSONB NOT NULL DEFAULT '{}',
        inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_crm_list_members_list_contact ON #{p}phoenix_kit_crm_list_members (list_uuid, contact_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_crm_list_members_list_email ON #{p}phoenix_kit_crm_list_members (list_uuid, email) WHERE email IS NOT NULL",
      "CREATE INDEX IF NOT EXISTS idx_crm_list_members_contact ON #{p}phoenix_kit_crm_list_members (contact_uuid)"
    ]
  end

  # ── guards ────────────────────────────────────────────────────────────

  # A guarded `ADD CONSTRAINT`, matched by name — the pattern core itself
  # uses (v135.ex) for constraints that `CREATE TABLE IF NOT EXISTS`
  # cannot express idempotently on its own.
  defp guarded_constraint(prefix, table, constraint_name, add_sql) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{constraint_name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        #{add_sql};
      END IF;
    END
    $$
    """
  end

  defp parse_version(n) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    # Interpolated into DDL — same guard the Legal/projects chains use.
    unless prefix =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end

    prefix
  end
end
