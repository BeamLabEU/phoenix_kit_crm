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

  V01 is an ADOPTION step for the nine pre-existing `phoenix_kit_crm_*`
  tables, plus one genuinely new column on a tenth:

    * on existing installs every table is already there (core's V135 /
      V138 / V148 / V151 / V152) — the `CREATE TABLE IF NOT EXISTS` /
      guarded `DO $$ ... pg_constraint ... $$` blocks for those nine all
      find their targets already in place and are no-ops. The one
      `ADD COLUMN IF NOT EXISTS` statement in this chain is NOT one of
      those no-ops: it is the sole genuinely new object,
      `phoenix_kit_crm_companies.user_uuid` (nullable FK →
      `phoenix_kit_users`, `ON DELETE SET NULL`), which does not exist
      on any pre-chain install — along with its partial unique index
      `idx_crm_companies_user_uuid` and the `crm_schema:1` marker.
      From then on this chain owns every adopted table's future shape;
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

  `CREATE TABLE IF NOT EXISTS` adoption is a presence check only — it
  does not repair a table whose columns/constraints have drifted from
  core's current shape on a host stuck before core V151/V152. That risk
  is contained, not eliminated: core's own migration chain always runs
  ahead of this one (`mix phoenix_kit.update` applies core's chain
  first), so by the time V01 runs, every adopted table is already at
  core's current shape on any host this chain actually executes against.

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

  @current_version 6
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
      v2_statements(p),
      v3_statements(p),
      v4_statements(prefix, p),
      v5_statements(prefix, p),
      v6_statements(p),
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

  # ── V02 ─────────────────────────────────────────────────────────────
  # Purely additive: one new column, so nothing is owed to core's
  # ExpectedSchema manifest (an extra column on a manifest-known table is
  # an info-level finding, never drift — the precedent is
  # `phoenix_kit_doc_documents.project_uuid` and the five columns the
  # projects chain added to `phoenix_kit_project_assignments`).
  #
  # `description` was the last field the catalogue's own supplier rows
  # carried that a CRM company did not, now that suppliers are managed
  # here rather than in the catalogue. Everything else they held is
  # already covered, and covered better: structured `email`/`phone`/
  # `address` instead of one free-text "email or phone" line.
  defp v2_statements(p) do
    [
      "ALTER TABLE #{p}phoenix_kit_crm_companies ADD COLUMN IF NOT EXISTS description TEXT"
    ]
  end

  # ── V03 ─────────────────────────────────────────────────────────────
  # Manufacturers moved here too, so a company can carry the brand mark
  # the catalogue's manufacturer rows used to hold. Additive, same lane
  # as V02.
  defp v3_statements(p) do
    [
      "ALTER TABLE #{p}phoenix_kit_crm_companies ADD COLUMN IF NOT EXISTS logo_url VARCHAR(500)"
    ]
  end

  # ── V04 ─────────────────────────────────────────────────────────────
  # Two integrity constraints the party-role table has always wanted, both
  # from an external review of the role system.
  #
  # 1. A CHECK on the vocabulary. It was changeset-only, so insert_all, a
  #    migration, psql or a future module could write a value the UI can never
  #    remove: `sync_roles/3` iterates the KNOWN roles, so a typo'd row is
  #    immortal garbage that renders raw in badges. Adding a role already
  #    requires a deploy, and this chain runs on deploy, so the constraint
  #    costs nothing it did not already cost.
  #
  # 2. A partial unique index on (roleable_uuid, role) WHERE is_active. Party
  #    uuids are globally unique, so one uuid holding the same ACTIVE role as
  #    both a company and a contact is not a state that can legitimately
  #    exist -- and it is the state `get_supplier/1` had to defend against
  #    with limit(1) and a deterministic sort. Making it impossible is better
  #    than resolving it consistently.
  defp v4_statements(prefix, p) do
    [
      # Legacy data FIRST. 0.2.x wrote `client` before the value was renamed to
      # `customer`, and ADD CONSTRAINT validates existing rows — so on any
      # install still holding one, adding the CHECK below would abort the whole
      # migration. This is the same normalisation `rename_legacy_client_roles/0`
      # performs, done in SQL so it cannot be skipped: drop the legacy row where
      # the party already holds `customer` (the unique index would reject the
      # rename), then rename whatever is left.
      """
      DO $$
      BEGIN
        -- Drop the legacy row only when it is genuinely redundant: the party
        -- already holds a LIVE `customer`, or the legacy row is itself
        -- dormant. Testing merely that SOME `customer` exists would delete an
        -- ACTIVE `client` because of a long-revoked `customer`, silently
        -- stripping a live role.
        DELETE FROM #{p}phoenix_kit_crm_party_roles legacy
        WHERE legacy.role = 'client'
          AND EXISTS (
            SELECT 1 FROM #{p}phoenix_kit_crm_party_roles current
            WHERE current.roleable_type = legacy.roleable_type
              AND current.roleable_uuid = legacy.roleable_uuid
              AND current.role = 'customer'
              AND (current.is_active OR NOT legacy.is_active)
          );

        -- The mirror case: a dormant `customer` sitting beside a live
        -- `client`. Drop the dormant one so the rename below does not collide
        -- with the pre-existing (roleable_type, roleable_uuid, role) index.
        DELETE FROM #{p}phoenix_kit_crm_party_roles dormant
        WHERE dormant.role = 'customer'
          AND NOT dormant.is_active
          AND EXISTS (
            SELECT 1 FROM #{p}phoenix_kit_crm_party_roles live
            WHERE live.roleable_type = dormant.roleable_type
              AND live.roleable_uuid = dormant.roleable_uuid
              AND live.role = 'client'
              AND live.is_active
          );

        UPDATE #{p}phoenix_kit_crm_party_roles SET role = 'customer' WHERE role = 'client';
      END $$;
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_crm_party_roles_role_check'
            AND t.relname = 'phoenix_kit_crm_party_roles'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_crm_party_roles
            ADD CONSTRAINT phoenix_kit_crm_party_roles_role_check
            CHECK (role IN ('supplier', 'customer', 'partner', 'manufacturer'));
        END IF;
      END $$;
      """,
      # The OLD index is (roleable_type, roleable_uuid, role), so one uuid
      # holding the same active role as BOTH a company and a contact was
      # legal — and `get_party_with_role/2`'s `limit(1)` existed precisely to
      # paper over it. The new index forbids it, so on any install carrying
      # that state `CREATE UNIQUE INDEX` would abort the whole migration.
      # Deactivate the losers first, company first (the documented intent),
      # then oldest, with uuid as a total tiebreak.
      """
      DO $$
      BEGIN
      WITH ranked AS (
        SELECT uuid,
               row_number() OVER (
                 PARTITION BY roleable_uuid, role
                 ORDER BY (roleable_type = 'company') DESC, inserted_at ASC, uuid ASC
               ) AS rn
        FROM #{p}phoenix_kit_crm_party_roles
        WHERE is_active
      )
      UPDATE #{p}phoenix_kit_crm_party_roles AS pr
      SET is_active = FALSE,
          valid_to = COALESCE(pr.valid_to, CURRENT_DATE)
      FROM ranked AS r
      WHERE pr.uuid = r.uuid AND r.rn > 1;
      END $$;
      """,
      """
      CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_crm_party_roles_active_uniq
        ON #{p}phoenix_kit_crm_party_roles (roleable_uuid, role)
        WHERE is_active
      """
    ]
  end

  # ── V05: company-anchored interactions ──────────────────────────────
  #
  # The v2 design doc's Phase 5: an interaction's ANCHOR (the record it is
  # about — `subject` is the title column, hence the different word) becomes
  # contact XOR company. Exclusive arc with hard FKs, not a polymorphic
  # type+uuid pair: both anchor tables are CRM-local so FK integrity is free,
  # and a dangling anchor — unlike a dangling party, which still renders via
  # `raw_name` — would be orphaned content. NO data migration: every existing
  # row has a contact and no company, so it satisfies the CHECK as-is.
  #
  # Statement order matters: the CHECK must exist before contact_uuid loses
  # NOT NULL, or a concurrently-replayed chain could briefly admit an
  # anchorless row. The CHECK is added NOT VALID and validated separately —
  # trivially true here, but VALIDATE takes only SHARE UPDATE EXCLUSIVE, so
  # the pattern stays right if this ever replays on a big install.
  defp v5_statements(prefix, p) do
    [
      "ALTER TABLE #{p}phoenix_kit_crm_interactions ADD COLUMN IF NOT EXISTS company_uuid UUID",
      # `ADD COLUMN IF NOT EXISTS ... REFERENCES` would not guard the FK on
      # replay when the column already exists — the FK needs its own guard,
      # anchored on any FK constraint over the column (the workspace's
      # add_if_not_exists-vs-references lesson).
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE t.relname = 'phoenix_kit_crm_interactions'
            AND n.nspname = '#{prefix}'
            AND c.contype = 'f'
            AND EXISTS (
              SELECT 1 FROM unnest(c.conkey) k
              JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k
              WHERE a.attname = 'company_uuid'
            )
        ) THEN
          ALTER TABLE #{p}phoenix_kit_crm_interactions
            ADD CONSTRAINT phoenix_kit_crm_interactions_company_uuid_fkey
            FOREIGN KEY (company_uuid)
            REFERENCES #{p}phoenix_kit_crm_companies(uuid)
            ON DELETE CASCADE;
        END IF;
      END $$;
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_crm_interactions_anchor_xor'
            AND t.relname = 'phoenix_kit_crm_interactions'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_crm_interactions
            ADD CONSTRAINT phoenix_kit_crm_interactions_anchor_xor
            CHECK (num_nonnulls(contact_uuid, company_uuid) = 1)
            NOT VALID;
        END IF;
      END $$;
      """,
      """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_crm_interactions_anchor_xor'
            AND t.relname = 'phoenix_kit_crm_interactions'
            AND n.nspname = '#{prefix}'
            AND NOT c.convalidated
        ) THEN
          ALTER TABLE #{p}phoenix_kit_crm_interactions
            VALIDATE CONSTRAINT phoenix_kit_crm_interactions_anchor_xor;
        END IF;
      END $$;
      """,
      """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_attribute a
          JOIN pg_class t ON t.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE t.relname = 'phoenix_kit_crm_interactions'
            AND n.nspname = '#{prefix}'
            AND a.attname = 'contact_uuid'
            AND a.attnotnull
        ) THEN
          ALTER TABLE #{p}phoenix_kit_crm_interactions
            ALTER COLUMN contact_uuid DROP NOT NULL;
        END IF;
      END $$;
      """,
      """
      CREATE INDEX IF NOT EXISTS idx_crm_interactions_company
        ON #{p}phoenix_kit_crm_interactions (company_uuid, occurred_at DESC, inserted_at DESC)
        WHERE company_uuid IS NOT NULL
      """
    ]
  end

  # ── V6: the zone an interaction time was typed in ─────────────────────
  #
  # `occurred_at` is a UTC instant; the wall clock the person typed lived
  # only in their profile's timezone AT THAT MOMENT. When that value moved to
  # IANA ids and the composer turned out to have read it as 0, the rows could
  # not be repaired — nothing said which zone each one was entered in. The
  # column carries it from now on (an IANA id or a legacy offset, the value as
  # core keeps it); nullable, because rows written before it hold no answer.
  defp v6_statements(p) do
    [
      "ALTER TABLE #{p}phoenix_kit_crm_interactions ADD COLUMN IF NOT EXISTS time_zone character varying(64)"
    ]
  end

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
    # \A..\z, not ^..$: PCRE's $ also matches before a trailing newline, so
    # "public\n" would pass the anchored-line form. Nothing exploitable
    # follows (the newline lands inside a quoted literal), but the guard
    # should mean what it says.
    unless prefix =~ ~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/ do
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end

    prefix
  end
end
