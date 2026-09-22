Warning: truncated output (original token count: 80105)
Total output lines: 10211

export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  graphql_public: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      graphql: {
        Args: {
          extensions?: Json
          operationName?: string
          query?: string
          variables?: Json
        }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  public: {
    Tables: {
      channel_integrations: {
        Row: { organization_id: string; profile_id: string; credential_encrypted: string; created_at: string; updated_at: string }
        Insert: { organization_id: string; profile_id: string; credential_encrypted: string; created_at?: string; updated_at?: string }
        Update: { organization_id?: string; profile_id?: string; credential_encrypted?: string; created_at?: string; updated_at?: string }
        Relationships: [{ foreignKeyName: "channel_integrations_organization_id_fkey"; columns: ["organization_id"]; isOneToOne: true; referencedRelation: "organizations"; referencedColumns: ["id"] }]
      }
      ai_reply_drafts: {
        Row: {
          id: string;
          organization_id: string;
          conversation_id: string;
          contact_id: string;
          agent_id: string;
          agent_version_id: string;
          channel_session_id: string;
          service_boundary: Json;
          context_revision: number;
          operation_revision: number;
          generation_token: string;
          revision: number;
          status: string;
          original_body: string | null;
          edited_body: string | null;
          approved_body: string | null;
          proposals: Json;
          trace: Json;
          feedback: Json | null;
          approved_by: string | null;
          approved_support_session_id: string | null;
          approved_at: string | null;
          send_job_id: string | null;
          message_id: string | null;
          error_code: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          organization_id?: string;
          conversation_id?: string;
          contact_id?: string;
          agent_id?: string;
          agent_version_id?: string;
          channel_session_id?: string;
          service_boundary?: Json;
          context_revision?: number;
          operation_revision?: number;
          generation_token?: string;
          revision?: number;
          status?: string;
          original_body?: string | null;
          edited_body?: string | null;
          approved_body?: string | null;
          proposals?: Json;
          trace?: Json;
          feedback?: Json | null;
          approved_by?: string | null;
          approved_support_session_id?: string | null;
          approved_at?: string | null;
          send_job_id?: string | null;
          message_id?: string | null;
          error_code?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          organization_id?: string;
          conversation_id?: string;
          contact_id?: string;
          agent_id?: string;
          agent_version_id?: string;
          channel_session_id?: string;
          service_boundary?: Json;
          context_revision?: number;
          operation_revision?: number;
          generation_token?: string;
          revision?: number;
          status?: string;
          original_body?: string | null;
          edited_body?: string | null;
          approved_body?: string | null;
          proposals?: Json;
          trace?: Json;
          feedback?: Json | null;
          approved_by?: string | null;
          approved_support_session_id?: string | null;
          approved_at?: string | null;
          send_job_id?: string | null;
          message_id?: string | null;
          error_code?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [];
      }
      financial_accounts: {
        Row: {
          created_at: string
          currency: string
          id: string
          is_active: boolean
          kind: string
          name: string
          opening_balance_cents: number
          organization_id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          currency?: string
          id?: string
          is_active?: boolean
          kind?: string
          name: string
          opening_balance_cents?: number
          organization_id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          currency?: string
          id?: string
          is_active?: boolean
          kind?: string
          name?: string
          opening_balance_cents?: number
          organization_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "financial_accounts_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      payment_methods: {
        Row: {
          account_id: string | null
          created_at: string
          id: string
          is_active: boolean
          name: string
          organization_id: string
          updated_at: string
        }
        Insert: {
          account_id?: string | null
          created_at?: string
          id?: string
          is_active?: boolean
          name: string
          organization_id: string
          updated_at?: string
        }
        Update: {
          account_id?: string | null
          created_at?: string
          id?: string
          is_active?: boolean
          name?: string
          organization_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "payment_methods_account_id_fkey"
            columns: ["account_id"]
            referencedRelation: "financial_accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_methods_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      account_plans: {
        Row: {
          created_at: string
          direction: string
          id: string
          is_active: boolean
          name: string
          organization_id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          direction: string
          id?: string
          is_active?: boolean
          name: string
          organization_id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          direction?: string
          id?: string
          is_active?: boolean
          name?: string
          organization_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "account_plans_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      sales: {
        Row: {
          appointment_id: string | null
          attendant_user_id: string | null
          cancel_reason: string | null
          cancelled_at: string | null
          contact_id: string | null
          created_at: string
          created_by_user_id: string | null
          currency: string
          discount_cents: number
          finalized_at: string | null
          id: string
          notes: string | null
          number: number
          organization_id: string
          payment_method_id: string | null
          reverse_reason: string | null
          reversed_at: string | null
          status: string
          total_cents: number
          updated_at: string
        }
        Insert: {
          appointment_id?: string | null
          attendant_user_id?: string | null
          cancel_reason?: string | null
          cancelled_at?: string | null
          contact_id?: string | null
          created_at?: string
          created_by_user_id?: string | null
          currency?: string
          discount_cents?: number
          finalized_at?: string | null
          id?: string
          notes?: string | null
          number: number
          organization_id: string
          payment_method_id?: string | null
          reverse_reason?: string | null
          reversed_at?: string | null
          status?: string
          total_cents?: number
          updated_at?: string
        }
        Update: {
          appointment_id?: string | null
          attendant_user_id?: string | null
          cancel_reason?: string | null
          cancelled_at?: string | null
          contact_id?: string | null
          created_at?: string
          created_by_user_id?: string | null
          currency?: string
          discount_cents?: number
          finalized_at?: string | null
          id?: string
          notes?: string | null
          number?: number
          organization_id?: string
          payment_method_id?: string | null
          reverse_reason?: string | null
          reversed_at?: string | null
          status?: string
          total_cents?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "sales_appointment_id_fkey"
            columns: ["appointment_id"]
            referencedRelation: "calendar_appointments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_contact_id_fkey"
            columns: ["contact_id"]
            referencedRelation: "contacts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_payment_method_id_fkey"
            columns: ["payment_method_id"]
            referencedRelation: "payment_methods"
            referencedColumns: ["id"]
          },
        ]
      }
      sale_items: {
        Row: {
          attendant_user_id: string | null
          commission_percent: number
          created_at: string
          description: string
          discount_cents: number
          event_type_id: string | null
          id: string
          organization_id: string
          quantity: number
          sale_id: string
          total_cents: number
          unit_price_cents: number
        }
        Insert: {
          attendant_user_id?: string | null
          commission_percent?: number
          created_at?: string
          description: string
          discount_cents?: number
          event_type_id?: string | null
          id?: string
          organization_id: string
          quantity?: number
          sale_id: string
          total_cents: number
          unit_price_cents: number
        }
        Update: {
          attendant_user_id?: string | null
          commission_percent?: number
          created_at?: string
          description?: string
          discount_cents?: number
          event_type_id?: string | null
          id?: string
          organization_id?: string
          quantity?: number
          sale_id?: string
          total_cents?: number
          unit_price_cents?: number
        }
        Relationships: [
          {
            foreignKeyName: "sale_items_event_type_id_fkey"
            columns: ["event_type_id"]
            referencedRelation: "calendar_event_types"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sale_items_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sale_items_sale_id_fkey"
            columns: ["sale_id"]
            referencedRelation: "sales"
            referencedColumns: ["id"]
          },
        ]
      }
      commission_rules: {
        Row: {
          attendant_user_id: string | null
          created_at: string
          event_type_id: string | null
          id: string
          organization_id: string
          percent: number
          name: string
          is_active: boolean
        }
        Insert: {
          attendant_user_id?: string | null
          created_at?: string
          event_type_id?: string | null
          id?: string
          organization_id: string
          percent: number
          name?: string
          is_active?: boolean
        }
        Update: {
          attendant_user_id?: string | null
          created_at?: string
          event_type_id?: string | null
          id?: string
          organization_id?: string
          percent?: number
          name?: string
          is_active?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "commission_rules_event_type_id_fkey"
            columns: ["event_type_id"]
            referencedRelation: "calendar_event_types"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "commission_rules_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      commissions: {
        Row: {
          amount_cents: number
          attendant_user_id: string
          created_at: string
          id: string
          organization_id: string
          paid_at: string | null
          percent: number
          reversed_at: string | null
          sale_item_id: string
          status: string
        }
        Insert: {
          amount_cents: number
          attendant_user_id: string
          created_at?: string
          id?: string
          organization_id: string
          paid_at?: string | null
          percent: number
          reversed_at?: string | null
          sale_item_id: string
          status?: string
        }
        Update: {
          amount_cents?: number
          attendant_user_id?: string
          created_at?: string
          id?: string
          organization_id?: string
          paid_at?: string | null
          percent?: number
          reversed_at?: string | null
          sale_item_id?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "commissions_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "commissions_sale_item_id_fkey"
            columns: ["sale_item_id"]
            referencedRelation: "sale_items"
            referencedColumns: ["id"]
          },
        ]
      }
      financial_entries: {
        Row: {
          account_id: string
          account_plan_id: string | null
          amount_cents: number
          created_at: string
          created_by_user_id: string | null
          currency: string
          description: string | null
          direction: string
          entry_date: string
          id: string
          organization_id: string
          origin: string
          paid_at: string | null
          reverses_entry_id: string | null
          recurring_entry_id: string | null
          sale_id: string | null
          status: string
          updated_at: string
        }
        Insert: {
          account_id: string
          account_plan_id?: string | null
          amount_cents: number
          created_at?: string
          created_by_user_id?: string | null
          currency?: string
          description?: string | null
          direction: string
          entry_date?: string
          id?: string
          organization_id: string
          origin?: string
          paid_at?: string | null
          reverses_entry_id?: string | null
          recurring_entry_id?: string | null
          sale_id?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          account_id?: string
          account_plan_id?: string | null
          amount_cents?: number
          created_at?: string
          created_by_user_id?: string | null
          currency?: string
          description?: string | null
          direction?: string
          entry_date?: string
          id?: string
          organization_id?: string
          origin?: string
          paid_at?: string | null
          reverses_entry_id?: string | null
          recurring_entry_id?: string | null
          sale_id?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "financial_entries_account_id_fkey"
            columns: ["account_id"]
            referencedRelation: "financial_accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "financial_entries_account_plan_id_fkey"
            columns: ["account_plan_id"]
            referencedRelation: "account_plans"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "financial_entries_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "financial_entries_sale_id_fkey"
            columns: ["sale_id"]
            referencedRelation: "sales"
            referencedColumns: ["id"]
          },
        ]
      }
      loyalty_ledger: {
        Row: {
          contact_id: string
          created_at: string
          created_by_user_id: string | null
          id: string
          idempotency_key: string | null
          organization_id: string
          points: number
          reason: string
          sale_id: string | null
          sale_item_id: string | null
        }
        Insert: {
          contact_id: string
          created_at?: string
          created_by_user_id?: string | null
          id?: string
          idempotency_key?: string | null
          organization_id: string
          points: number
          reason: string
          sale_id?: string | null
          sale_item_id?: string | null
        }
        Update: {
          contact_id?: string
          created_at?: string
          created_by_user_id?: string | null
          id?: string
          idempotency_key?: string | null
          organization_id?: string
          points?: number
          reason?: string
          sale_id?: string | null
          sale_item_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "loyalty_ledger_contact_id_fkey"
            columns: ["contact_id"]
            referencedRelation: "contacts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "loyalty_ledger_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "loyalty_ledger_sale_id_fkey"
            columns: ["sale_id"]
            referencedRelation: "sales"
            referencedColumns: ["id"]
          },
        ]
      }
      recurring_entries: {
        Row: {
          account_id: string
          account_plan_id: string | null
          amount_cents: number
          created_at: string
          created_by_user_id: string | null
          currency: string
          day_of_month: number
          direction: string
          id: string
          is_active: boolean
          name: string
          organization_id: string
          updated_at: string
        }
        Insert: {
          account_id: string
          account_plan_id?: string | null
          amount_cents: number
          created_at?: string
          created_by_user_id?: string | null
          currency?: string
          day_of_month: number
          direction: string
          id?: string
          is_active?: boolean
          name: string
          organization_id: string
          updated_at?: string
        }
        Update: {
          account_id?: string
          account_plan_id?: string | null
          amount_cents?: number
          created_at?: string
          created_by_user_id?: string | null
          currency?: string
          day_of_month?: number
          direction?: string
          id?: string
          is_active?: boolean
          name?: string
          organization_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "recurring_entries_account_id_fkey"
            columns: ["account_id"]
            referencedRelation: "financial_accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "recurring_entries_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      channel_routing_policies: {
        Row: {
          channel_session_id: string
          created_at: string
          id: string
          organization_id: string
          updated_at: string
        }
        Insert: {
          channel_session_id: string
          created_at?: string
          id?: string
          organization_id: string
          updated_at?: string
        }
        Update: {
          channel_session_id?: string
          created_at?: string
          id?: string
          organization_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "channel_routing_policies_organization_id_channel_session_i_fkey"
            columns: ["organization_id", "channel_session_id"]
            referencedRelation: "channel_sessions"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "channel_routing_policies_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      channel_routing_responsibles: {
        Row: {
          created_at: string
          organization_id: string
          policy_id: string
          user_id: string
        }
        Insert: {
          created_at?: string
          organization_id: string
          policy_id: string
          user_id: string
        }
        Update: {
          created_at?: string
          organization_id?: string
          policy_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "channel_routing_responsibles_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "channel_routing_responsibles_organization_id_policy_id_fkey"
            columns: ["organization_id", "policy_id"]
            referencedRelation: "channel_routing_policies"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "channel_routing_responsibles_organization_id_user_id_fkey"
            columns: ["organization_id", "user_id"]
            referencedRelation: "user_organizations"
            referencedColumns: ["organization_id", "user_id"]
          },
        ]
      }
      channel_connection_requests: {
        Row: {
          channel_session_id: string | null
          created_at: string
          id: string
          idempotency_key: string
          lease_token: string
          lease_until: string
          organization_id: string
          remote_created: boolean
          request_hash: string
          state: string
          updated_at: string
        }
        Insert: {
          channel_session_id?: string | null
          created_at?: string
          id?: string
          idempotency_key: string
          lease_token?: string
          lease_until?: string
          organization_id: string
          remote_created?: boolean
          request_hash: string
          state?: string
          updated_at?: string
        }
        Update: {
          channel_session_id?: string | null
          created_at?: string
          id?: string
          idempotency_key?: string
          lease_token?: string
          lease_until?: string
          organization_id?: string
          remote_created?: boolean
          request_hash?: string
          state?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "channel_connection_requests_organization_id_channel_sessio_fkey"
            columns: ["organization_id", "channel_session_id"]
            referencedRelation: "channel_sessions"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "channel_connection_requests_organization_id_fkey"
            columns: ["organization_id"]
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }

      appointment_recovery_receipts: {
        Row: { organization_id: string; appointment_id: string; appointment_revision: number; source_event_id: string | null; result: string; pointer_id: string | null; enrollment_id: string | null; recorded_at: string; invalidated_at: string | null }
        Insert: { organization_id: string; appointment_id: string; appointment_revision: number; source_event_id?: string | null; result: string; pointer_id?: string | null; enrollment_id?: string | null; recorded_at?: string; invalidated_at?: string | null }
        Update: { organization_id?: string; appointment_id?: string; appointment_revision?: number; source_event_id?: string | null; result?: string; pointer_id?: string | null; enrollment_id?: string | null; recorded_at?: string; invalidated_at?: string | null }
        Relationships: [
          { foreignKeyName: "appointment_recovery_receipts_organization_id_fkey"; columns: ["organization_id"]; isOneToOne: false; referencedRelation: "organizations"; referencedColumns: ["id"] },
          { foreignKeyName: "appointment_recovery_receipts_appointment_id_fkey"; columns: ["appointment_id"]; isOneToOne: false; referencedRelation: "calendar_appointments"; referencedColumns: ["id"] },
          { foreignKeyName: "appointment_recovery_receipts_source_event_id_fkey"; columns: ["source_event_id"]; isOneToOne: false; referencedRelation: "event_log"; referencedColumns: ["id"] },
          { foreignKeyName: "appointment_recovery_receipts_pointer_id_fkey"; columns: ["pointer_id"]; isOneToOne: false; referencedRelation: "followup_flow_pointers"; referencedColumns: ["id"] },
          { foreignKeyName: "appointment_recovery_receipts_enrollment_id_fkey"; columns: ["enrollment_id"]; isOneToOne: false; referencedRelation: "followup_enrollments"; referencedColumns: ["id"] }
        ]
      }
      event_service_origins: {
        Row: { event_id: string; channel_session_id: string; organization_id: string; service_boundary: Json }
        Insert: { event_id: string; channel_session_id: string; organization_id: string; service_boundary: Json }
        Update: { event_id?: string; channel_session_id?: string; organization_id?: string; service_boundary?: Json }
        Relationships: [
          { foreignKeyName: "event_service_origins_channel_session_id_fkey"; columns: ["channel_session_id"]; isOneToOne: false; referencedRelation: "channel_sessions"; referencedColumns: ["id"] },
          { foreignKeyName: "event_service_origins_event_id_fkey"; columns: ["event_id"]; isOneToOne: false; referencedRelation: "event_log"; referencedColumns: ["id"] },
          { foreignKeyName: "event_service_origins_organization_id_fkey"; columns: ["organization_id"]; isOneToOne: false; referencedRelation: "organizations"; referencedColumns: ["id"] }
        ]
      }

      platform_support_sessions: {
        Row: { id: string; organization_id: string; actor_user_id: string; auth_session_id: string; access_mode: string; previous_organization_id: string | null; created_at: string; expires_at: string; ended_at: string | null }
        Insert: { id?: string; organization_id: string; actor_user_id: string; auth_session_id: string; access_mode: string; previous_organization_id?: string | null; created_at?: string; expires_at: string; ended_at?: string | null }
        Update: { id?: string; organization_id?: string; actor_user_id?: string; auth_session_id?: string; access_mode?: string; previous_organization_id?: string | null; created_at?: string; expires_at?: string; ended_at?: string | null }
        Relationships: [{ foreignKeyName: "platform_support_sessions_organization_id_fkey"; columns: ["organization_id"]; isOneToOne: false; referencedRelation: "organizations"; referencedColumns: ["id"] }]
      }

      ad_conversion_dispatches: {
        Row: {
          attempted_at: string
          created_at: string
          currency: string | null
          detail: string | null
          event_id: string | null
          event_name: string
          id: string
          lead_id: string
          organization_id: string
          platform: string
          reason: string | null
          status: string
          updated_at: string
          value_cents: number | null
        }
        Insert: {
          attempted_at?: string
          created_at?: string
          currency?: string | null
          detail?: string | null
          event_id?: string | null
          event_name: string
          id?: string
          lead_id: string
          organization_id: string
          platform: string
          reason?: string | null
          status: string
          updated_at?: string
          value_cents?: number | null
        }
        Update: {
          attempted_at?: string
          created_at?: string
          currency?: string | null
          detail?: string | null
          event_id?: string | null
          event_name?: string
          id?: string
          lead_id?: string
          organization_id?: string
          platform?: string
          reason?: string | null
          status?: string
          updated_at?: string
          value_cents?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "ad_conversion_dispatches_lead_id_fkey"
            columns: ["lead_id"]
            isOneToOne: false
            referencedRelation: "crm_leads"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ad_conversion_dispatches_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      ad_platform_connections: {
        Row: {
          access_token_encrypted: string | null
          created_at: string
          dataset_id: string | null
          enabled: boolean
          google_conversion_action_id: string | null
          google_customer_id: string | null
          google_login_customer_id: string | null
          google_refresh_token_encrypted: string | null
          id: string
          organization_id: string
          platform: string
          test_event_code: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          access_token_encrypted?: string | null
          created_at?: string
          dataset_id?: string | null
          enabled?: boolean
          google_conversion_action_id?: string | null
          google_customer_id?: string | null
          google_login_customer_id?: string | null
          google_refresh_token_encrypted?: string | null
          id?: string
          organization_id: string
          platform: string
          test_event_code?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          access_token_encrypted?: string | null
          created_at?: string
          dataset_id?: string | null
          enabled?: boolean
          google_conversion_action_id?: string | null
          google_customer_id?: string | null
          google_login_customer_id?: string | null
          google_refresh_token_encrypted?: string | null
          id?: string
          organization_id?: string
          platform?: string
          test_event_code?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "ad_platform_connections_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      agent_case_chat_messages: {
        Row: {
          agent_id: string | null
          author_kind: string
          author_user_id: string | null
          body: string | null
          case_id: string
          contact_id: string
          conversation_id: string
          created_at: string
          error_code: string | null
          id: string
          llm_call_id: string | null
          organization_id: string
          redacted_at: string | null
          service_stale: boolean
          turn_id: string
        }
        Insert: {
          agent_id?: string | null
          author_kind: string
          author_user_id?: string | null
          body?: string | null
          case_id: string
          contact_id: string
          conversation_id: string
          created_at?: string
          error_code?: string | null
          id?: string
          llm_call_id?: string | null
          organization_id: string
          redacted_at?: string | null
          service_stale?: boolean
          turn_id: string
        }
        Update: {
          agent_id?: string | null
          author_kind?: string
          author_user_id?: string | null
          body?: string | null
          case_id?: string
          contact_id?: string
          conversation_id?: string
          created_at?: string
          error_code?: string | null
          id?: string
          llm_call_id?: string | null
          organization_id?: string
          redacted_at?: string | null
          service_stale?: boolean
          turn_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "agent_case_chat_messages_case_id_fkey"
            columns: ["case_id"]
            isOneToOne: false
            referencedRelation: "agent_cases"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_case_chat_messages_contact_id_fkey"
            columns: ["contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_case_chat_messages_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_case_chat_messages_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      agent_case_events: {
        Row: {
          actor_kind: string
          actor_user_id: string | null
          body: string | null
          case_id: string
          created_at: string
          human_action: string | null
          id: string
          kind: string
          metadata: Json
          organization_id: string
        }
        Insert: {
          actor_kind: string
          actor_user_id?: string | null
          body?: string | null
          case_id: string
          created_at?: string
          human_action?: string | null
          id?: string
          kind: string
          metadata?: Json
          organization_id: string
        }
        Update: {
          actor_kind?: string
          actor_user_id?: string | null
          body?: string | null
          case_id?: string
          created_at?: string
          human_action?: string | null
          id?: string
          kind?: string
          metadata?: Json
          organization_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "agent_case_events_case_id_fkey"
            columns: ["case_id"]
            isOneToOne: false
            referencedRelation: "agent_cases"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_case_events_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      agent_cases: {
        Row: {
          agent_id: string | null
          blocker: string
          closed_at: string | null
          context_snapshot: Json
          conversation_id: string
          created_at: string
          followup_attempts: number
          id: string
          lead_id: string | null
          opened_at: string
          organization_id: string
          source: string
          status: string
          summary: string
          title: string
          updated_at: string
        }
        Insert: {
          agent_id?: string | null
          blocker: string
          closed_at?: string | null
          context_snapshot?: Json
          conversation_id: string
          created_at?: string
          followup_attempts?: number
          id?: string
          lead_id?: string | null
          opened_at?: string
          organization_id: string
          source?: string
          status?: string
          summary: string
          title: string
          updated_at?: string
        }
        Update: {
          agent_id?: string | null
          blocker?: string
          closed_at?: string | null
          context_snapshot?: Json
          conversation_id?: string
          created_at?: string
          followup_attempts?: number
          id?: string
          lead_id?: string | null
          opened_at?: string
          organization_id?: string
          source?: string
          status?: string
          summary?: string
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "agent_cases_agent_id_fkey"
            columns: ["agent_id"]
            isOneToOne: false
            referencedRelation: "ai_agents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_cases_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_cases_lead_id_fkey"
            columns: ["lead_id"]
            isOneToOne: false
            referencedRelation: "crm_leads"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_cases_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      agent_inbox_items: {
        Row: {
          appointment_revision: number | null
          body: string | null
          created_at: string
          id: string
          legacy_recovery_code: string | null
          kind: string
          organization_id: string | null
          ref_id: string | null
          ref_kind: string | null
          resolved_at: string | null
          severity: string
          status: string
          title: string
        }
        Insert: {
          appointment_revision?: number | null
          body?: string | null
          created_at?: string
          id?: string
          legacy_recovery_code?: string | null
          kind: string
          organization_id?: string | null
          ref_id?: string | null
          ref_kind?: string | null
          resolved_at?: string | null
          severity?: string
          status?: string
          title: string
        }
        Update: {
          appointment_revision?: number | null
          body?: string | null
          created_at?: string
          id?: string
          legacy_recovery_code?: string | null
          kind?: string
          organization_id?: string | null
          ref_id?: string | null
          ref_kind?: string | null
          resolved_at?: string | null
          severity?: string
          status?: string
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "agent_inbox_items_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      ai_agent_runs: {
        Row: {
          abort_reason: string | null
          agent_id: string
          agent_version_id: string
          channel_session_id: string | null
          completed_at: string | null
          contact_id: string | null
          conversation_id: string | null
          cost_cents: number
          created_at: string
          error_code: string | null
          error_message: string | null
          id: string
          inbound_message_id: string | null
          is_dry_run: boolean
          latency_ms: number | null
          organization_id: string
          outbound_message_id: string | null
          started_at: string
          status: string
          steps_count: number
          tokens_in: number
          tokens_out: number
          tool_calls: Json
        }
        Insert: {
          abort_reason?: string | null
          agent_id: string
          agent_version_id: string
          channel_session_id?: string | null
          completed_at?: string | null
          contact_id?: string | null
          conversation_id?: string | null
          cost_cents?: number
          created_at?: string
          error_code?: string | null
          error_message?: string | null
          id?: string
          inbound_message_id?: string | null
          is_dry_run?: boolean
          latency_ms?: number | null
          organization_id: string
          outbound_message_id?: string | null
          started_at?: string
          status?: string
          steps_count?: number
          tokens_in?: number
          tokens_out?: number
          tool_calls?: Json
        }
        Update: {
          abort_reason?: string | null
          agent_id?: string
          agent_version_id?: string
          channel_session_id?: string | null
          completed_at?: string | null
          contact_id?: string | null
          conversation_id?: string | null
          cost_cents?: number
          created_at?: string
          error_code?: string | null
          error_message?: string | null
          id?: string
          inbound_message_id?: string | null
          is_dry_run?: boolean
          latency_ms?: number | null
          organization_id?: string
          outbound_message_id?: string | null
          started_at?: string
          status?: string
          steps_count?: number
          tokens_in?: number
          tokens_out?: number
          tool_calls?: Json
        }
        Relationships: [
          {
            foreignKeyName: "ai_agent_runs_agent_id_fkey"
            columns: ["agent_id"]
            isOneToOne: false
            referencedRelation: "ai_agents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_agent_runs_agent_version_id_fkey"
            columns: ["agent_version_id"]
            isOneToOne: false
            referencedRelation: "ai_agent_versions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_agent_runs_channel_session_id_fkey"
            columns: ["channel_session_id"]
            isOneToOne: false
            referencedRelation: "channel_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_agent_runs_contact_id_fkey"
            columns: ["contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_agent_runs_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_agent_runs_inbound_message_id_fkey"
            columns: ["inbound_message_id"]
            isOneToOne: false
            referencedRelation: "messages"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_agent_runs_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_agent_runs_outbound_message_id_fkey"
            columns: ["outbound_message_id"]
            isOneToOne: false
            referencedRelation: "messages"
            referencedColumns: ["id"]
          },
        ]
      }
      ai_agent_versions: {
        Row: {
          provisioning_origin: string | null
          agent_id: string
          cases_enabled: boolean
          channel_session_id: string | null
          cost_budget_cents: number
          created_at: string
          created_by: string | null
          credential_id: string | null
          followup: Json
          handoff_keywords: string[]
          handoff_tool_enabled: boolean
          history_message_window: number
          history_token_window: number
          id: string
          knowledge_source_ids: string[]
          max_steps: number
          model: string
          multimodal_input: boolean
          operator_enabled: boolean
          operator_model: string | null
          operator_tool_ids: string[]
          organization_id: string
          pipeline_ids: string[]
          provider: string
          published_at: string | null
          split_max_chars: number
          split_messages: boolean
          status: string
          superseded_at: string | null
          system_prompt: string
          token_budget: number
          tool_ids: string[]
          trigger_config: Json
          version_number: number
          video_frames_enabled: boolean
        }
        Insert: {
          provisioning_origin?: string | null
          agent_id: string
          cases_enabled?: boolean
          channel_session_id: string | null
          cost_budget_cents?: number
          created_at?: string
          created_by?: string | null
          credential_id?: string | null
          followup?: Json
          handoff_keywords?: string[]
          handoff_tool_enabled?: boolean
          history_message_window?: number
          history_token_window?: number
          id?: string
          knowledge_source_ids?: string[]
          max_steps?: number
          model: string
          multimodal_input?: boolean
          operator_enabled?: boolean
          operator_model?: string | null
          operator_tool_ids?: string[]
          organization_id: string
          pipeline_ids?: string[]
          provider: string
          published_at?: string | null
          split_max_chars?: number
          split_messages?: boolean
          status?: string
          superseded_at?: string | null
          system_prompt: string
          token_budget?: number
          tool_ids?: string[]
          trigger_config?: Json
          version_number: number
          video_frames_enabled?: boolean
        }
        Update: {
          provisioning_origin?: string | null
          agent_id?: string
          cases_enabled?: boolean
          channel_session_id?: string | null
          cost_budget_cents?: number
          created_at?: string
          created_by?: string | null
          credential_id?: string | null
          followup?: Json
          handoff_keywords?: string[]
          handoff_tool_enabled?: boolean
          history_message_window?: number
          history_token_window?: number
          id?: string
          knowledge_source_ids?: string[]
          max_steps?: number
          model?: string
          multimodal_input?: boolean
          operator_enabled?: boolean
          operator_model?: string | null
          operator_tool_ids?: string[]
          organization_id?: string
          pipeline_ids?: string[]
          provider?: string
          published_at?: string | null
          split_max_chars?: number
          split_messages?: boolean
          status?: string
          superseded_at?: string | null
          system_prompt?: string
          token_budget?: number
          tool_ids?: string[]
          trigger_config?: Json
          version_number?: number
          video_frames_enabled?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "ai_agent_versions_agent_id_fkey"
            columns: ["agent_id"]
            isOneToOne: false
            referencedRelation: "ai_agents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_agent_versions_channel_session_id_fkey"
            columns: ["channel_session_id"]
            isOneToOne: false
            referencedRelation: "channel_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_agent_versions_credential_id_fkey"
            columns: ["credential_id"]
            isOneToOne: false
            referencedRelation: "ai_provider_credentials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_agent_versions_credential_id_fkey"
            columns: ["credential_id"]
            isOneToOne: false
            referencedRelation: "ai_provider_credentials_safe"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_agent_versions_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      ai_agents: {
        Row: {
          operation_mode: string
          paused_at: string | null
          operation_revision: number
          active_kb_version_id: string | null
          archived_at: string | null
          config: Json
          created_at: string
          created_by: string | null
          description: string | null
          guardrails: Json
          id: string
          is_active: boolean
          is_default: boolean
          kind: string
          model: string
          name: string
          organization_id: string
          priority: number
          published_version_id: string | null
          system_prompt: string
          updated_at: string
        }
        Insert: {
          operation_mode?: string
          paused_at?: string | null
          operation_revision?: number
          active_kb_version_id?: string | null
          archived_at?: string | null
          config?: Json
          created_at?: string
          created_by?: string | null
          description?: string | null
          guardrails?: Json
          id?: string
          is_active?: boolean
          is_default?: boolean
          kind?: string
          model?: string
          name: string
          organization_id: string
          priority?: number
          published_version_id?: string | null
          system_prompt: string
          updated_at?: string
        }
        Update: {
          operation_mode?: string
          paused_at?: string | null
          operation_revision?: number
          active_kb_version_id?: string | null
          archived_at?: string | null
          config?: Json
          created_at?: string
          created_by?: string | null
          description?: string | null
          guardrails?: Json
          id?: string
          is_active?: boolean
          is_default?: boolean
          kind?: string
          model?: string
          name?: string
          organization_id?: string
          priority?: number
          published_version_id?: string | null
          system_prompt?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "ai_agents_active_kb_version_id_fkey"
            columns: ["active_kb_version_id"]
            isOneToOne: false
            referencedRelation: "ai_knowledge_versions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_agents_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_agents_published_version_id_fkey"
            columns: ["published_version_id"]
            isOneToOne: false
            referencedRelation: "ai_agent_versions"
            referencedColumns: ["id"]
          },
        ]
      }
      ai_budgets: {
        Row: {
          action_at_100pct: string
          alarm_threshold_pct: number
          current_month_consumed_cents: number
          current_period_start: string
          enforcement_effective_at: string | null
          enforcement_mode: string
          is_disabled: boolean
          is_throttled: boolean
          last_alarm_sent_at: string | null
          monthly_limit_cents: number
          organization_id: string
          updated_at: string
        }
        Insert: {
          action_at_100pct?: string
          alarm_threshold_pct?: number
          current_month_consumed_cents?: number
          current_period_start?: string
          enforcement_effective_at?: string | null
          enforcement_mode?: string
          is_disabled?: boolean
          is_throttled?: boolean
          last_alarm_sent_at?: string | null
          monthly_limit_cents?: number
          organization_id: string
          updated_at?: string
        }
        Update: {
          action_at_100pct?: string
          alarm_threshold_pct?: number
          current_month_consumed_cents?: number
          current_period_start?: string
          enforcement_effective_at?: string | null
          enforcement_mode?: string
          is_disabled?: boolean
          is_throttled?: boolean
          last_alarm_sent_at?: string | null
          monthly_limit_cents?: number
          organization_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "ai_budgets_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: true
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      ai_chunks: {
        Row: {
          content: string
          content_hash: string
          created_at: string
          embedding: string
          id: string
          kb_version_id: string
          knowledge_source_id: string
          metadata: Json
          organization_id: string
          position: number
          token_count: number
        }
        Insert: {
          content: string
          content_hash: string
          created_at?: string
          embedding: string
          id?: string
          kb_version_id: string
          knowledge_source_id: string
          metadata?: Json
          organization_id: string
          position: number
          token_count: number
        }
        Update: {
          content?: string
          content_hash?: string
          created_at?: string
          embedding?: string
          id?: string
          kb_version_id?: string
          knowledge_source_id?: string
          metadata?: Json
          organization_id?: string
          position?: number
          token_count?: number
        }
        Relationships: [
          {
            foreignKeyName: "ai_chunks_kb_version_id_fkey"
            columns: ["kb_version_id"]
            isOneToOne: false
            referencedRelation: "ai_knowledge_versions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_chunks_knowledge_source_id_fkey"
            columns: ["knowledge_source_id"]
            isOneToOne: false
            referencedRelation: "ai_knowledge_sources"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_chunks_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      ai_faq_items: {
        Row: {
          answer: string
          created_at: string
          id: string
          knowledge_source_id: string
          locale: string
          organization_id: string
          position: number
          question: string
          tags: string[]
          updated_at: string
        }
        Insert: {
          answer: string
          created_at?: string
          id?: string
          knowledge_source_id: string
          locale?: string
          organization_id: string
          position?: number
          question: string
          tags?: string[]
          updated_at?: string
        }
        Update: {
          answer?: string
          created_at?: string
          id?: string
          knowledge_source_id?: string
          locale?: string
          organization_id?: string
          position?: number
          question?: string
          tags?: string[]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "ai_faq_items_knowledge_source_id_fkey"
            columns: ["knowledge_source_id"]
            isOneToOne: false
            referencedRelation: "ai_knowledge_sources"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ai_faq_items_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      ai_invocations: {
        Row: {
          agent_id: string | null
          citations: Json
          completion_tokens: number
          conversation_id: string | null
          cost_cents: number
          created_at: string
          error_payload: Json | null
          finish_reason: string | null
          id: string
          invocation_kind: string
          latency_ms: number
          message_id: string | null
          model: string
          organization_id: string
          prompt_blo…50105 tokens truncated…from_version?: string
          id?: string
          last_step?: string | null
          log_tail?: string
          passada_do_banco?: number | null
          requested_by?: string | null
          retentativas_do_banco?: number | null
          status?: string
          to_version?: string
        }
        Relationships: []
      }
      system_version: {
        Row: {
          agent_last_seen_at: string | null
          changelog_raw: string
          compare_failed: boolean
          current_sha: string
          current_version: string
          has_known_release: boolean
          id: number
          latest_version: string
          off_release: boolean
          update_requested_at: string | null
          update_requested_by: string | null
          updated_at: string
        }
        Insert: {
          agent_last_seen_at?: string | null
          changelog_raw?: string
          compare_failed?: boolean
          current_sha?: string
          current_version?: string
          has_known_release?: boolean
          id?: number
          latest_version?: string
          off_release?: boolean
          update_requested_at?: string | null
          update_requested_by?: string | null
          updated_at?: string
        }
        Update: {
          agent_last_seen_at?: string | null
          changelog_raw?: string
          compare_failed?: boolean
          current_sha?: string
          current_version?: string
          has_known_release?: boolean
          id?: number
          latest_version?: string
          off_release?: boolean
          update_requested_at?: string | null
          update_requested_by?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      tenant_integrations: {
        Row: {
          created_at: string
          expires_at: string | null
          id: string
          last_health_check_at: string | null
          last_sync_at: string | null
          oauth_access_token_encrypted: string
          oauth_refresh_token_encrypted: string | null
          organization_id: string
          provider: string
          scopes: string[]
          status: string
          status_reason: string | null
          store_metadata: Json
          updated_at: string
          webhook_path_token: string
          webhook_secret_encrypted: string
          webhook_subscriptions: Json
        }
        Insert: {
          created_at?: string
          expires_at?: string | null
          id?: string
          last_health_check_at?: string | null
          last_sync_at?: string | null
          oauth_access_token_encrypted: string
          oauth_refresh_token_encrypted?: string | null
          organization_id: string
          provider: string
          scopes?: string[]
          status?: string
          status_reason?: string | null
          store_metadata?: Json
          updated_at?: string
          webhook_path_token?: string
          webhook_secret_encrypted: string
          webhook_subscriptions?: Json
        }
        Update: {
          created_at?: string
          expires_at?: string | null
          id?: string
          last_health_check_at?: string | null
          last_sync_at?: string | null
          oauth_access_token_encrypted?: string
          oauth_refresh_token_encrypted?: string | null
          organization_id?: string
          provider?: string
          scopes?: string[]
          status?: string
          status_reason?: string | null
          store_metadata?: Json
          updated_at?: string
          webhook_path_token?: string
          webhook_secret_encrypted?: string
          webhook_subscriptions?: Json
        }
        Relationships: [
          {
            foreignKeyName: "tenant_integrations_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      user_organizations: {
        Row: {
          interface_settings: Json
          accepted_at: string | null
          calendar_trilha: number | null
          created_at: string
          id: string
          invited_at: string | null
          invited_by: string | null
          organization_id: string
          revoked_at: string | null
          role: string
          updated_at: string
          user_id: string
        }
        Insert: {
          interface_settings?: Json
          accepted_at?: string | null
          calendar_trilha?: number | null
          created_at?: string
          id?: string
          invited_at?: string | null
          invited_by?: string | null
          organization_id: string
          revoked_at?: string | null
          role: string
          updated_at?: string
          user_id: string
        }
        Update: {
          interface_settings?: Json
          accepted_at?: string | null
          calendar_trilha?: number | null
          created_at?: string
          id?: string
          invited_at?: string | null
          invited_by?: string | null
          organization_id?: string
          revoked_at?: string | null
          role?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_organizations_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      user_recovery_codes: {
        Row: {
          code_hash: string
          created_at: string
          id: string
          used_at: string | null
          used_ip: unknown
          user_id: string
        }
        Insert: {
          code_hash: string
          created_at?: string
          id?: string
          used_at?: string | null
          used_ip?: unknown
          user_id: string
        }
        Update: {
          code_hash?: string
          created_at?: string
          id?: string
          used_at?: string | null
          used_ip?: unknown
          user_id?: string
        }
        Relationships: []
      }
      voice_calls: {
        Row: {
          answered_at: string | null
          channel_session_id: string
          contact_id: string | null
          created_at: string
          created_by: string | null
          direction: string
          duration_ms: number | null
          end_reason: string | null
          ended_at: string | null
          id: string
          organization_id: string
          peer_phone: string
          started_at: string
          status: string
          updated_at: string
          wacalls_call_id: string
        }
        Insert: {
          answered_at?: string | null
          channel_session_id: string
          contact_id?: string | null
          created_at?: string
          created_by?: string | null
          direction: string
          duration_ms?: number | null
          end_reason?: string | null
          ended_at?: string | null
          id?: string
          organization_id: string
          peer_phone: string
          started_at?: string
          status: string
          updated_at?: string
          wacalls_call_id: string
        }
        Update: {
          answered_at?: string | null
          channel_session_id?: string
          contact_id?: string | null
          created_at?: string
          created_by?: string | null
          direction?: string
          duration_ms?: number | null
          end_reason?: string | null
          ended_at?: string | null
          id?: string
          organization_id?: string
          peer_phone?: string
          started_at?: string
          status?: string
          updated_at?: string
          wacalls_call_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "voice_calls_channel_session_id_fkey"
            columns: ["channel_session_id"]
            isOneToOne: false
            referencedRelation: "channel_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "voice_calls_contact_id_fkey"
            columns: ["contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "voice_calls_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      watchdog_cursors: {
        Row: {
          consumer: string
          last_created_at: string
          last_event_id: string
          updated_at: string
        }
        Insert: {
          consumer: string
          last_created_at?: string
          last_event_id?: string
          updated_at?: string
        }
        Update: {
          consumer?: string
          last_created_at?: string
          last_event_id?: string
          updated_at?: string
        }
        Relationships: []
      }
      webhook_events_log: {
        Row: {
          archived_at: string | null
          attempts: number
          channel_session_id: string | null
          error_message: string | null
          event_type: string | null
          external_id: string | null
          headers: Json | null
          http_method: string
          id: string
          organization_id: string | null
          payload_parsed: Json | null
          processed_at: string | null
          provider: string
          raw_body: string | null
          received_at: string
          signature_header: string | null
          status: string
          valid_signature: boolean | null
          webhook_path_token: string | null
        }
        Insert: {
          archived_at?: string | null
          attempts?: number
          channel_session_id?: string | null
          error_message?: string | null
          event_type?: string | null
          external_id?: string | null
          headers?: Json | null
          http_method?: string
          id?: string
          organization_id?: string | null
          payload_parsed?: Json | null
          processed_at?: string | null
          provider?: string
          raw_body?: string | null
          received_at?: string
          signature_header?: string | null
          status?: string
          valid_signature?: boolean | null
          webhook_path_token?: string | null
        }
        Update: {
          archived_at?: string | null
          attempts?: number
          channel_session_id?: string | null
          error_message?: string | null
          event_type?: string | null
          external_id?: string | null
          headers?: Json | null
          http_method?: string
          id?: string
          organization_id?: string | null
          payload_parsed?: Json | null
          processed_at?: string | null
          provider?: string
          raw_body?: string | null
          received_at?: string
          signature_header?: string | null
          status?: string
          valid_signature?: boolean | null
          webhook_path_token?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "webhook_events_log_channel_session_id_fkey"
            columns: ["channel_session_id"]
            isOneToOne: false
            referencedRelation: "channel_sessions"
            referencedColumns: ["id"]
          },
        ]
      }
      webhook_lead_captures: {
        Row: {
          captured_email: string | null
          captured_name: string | null
          captured_phone: string | null
          contact_id: string | null
          fields: Json
          id: string
          lead_id: string | null
          organization_id: string
          origin: string | null
          outcome: string
          received_at: string
          reject_reason: string | null
          remote_ip: unknown
          request_id: string | null
          source_name: string
          user_agent: string | null
          utm: Json
          webhook_source_id: string | null
        }
        Insert: {
          captured_email?: string | null
          captured_name?: string | null
          captured_phone?: string | null
          contact_id?: string | null
          fields?: Json
          id?: string
          lead_id?: string | null
          organization_id: string
          origin?: string | null
          outcome: string
          received_at?: string
          reject_reason?: string | null
          remote_ip?: unknown
          request_id?: string | null
          source_name: string
          user_agent?: string | null
          utm?: Json
          webhook_source_id?: string | null
        }
        Update: {
          captured_email?: string | null
          captured_name?: string | null
          captured_phone?: string | null
          contact_id?: string | null
          fields?: Json
          id?: string
          lead_id?: string | null
          organization_id?: string
          origin?: string | null
          outcome?: string
          received_at?: string
          reject_reason?: string | null
          remote_ip?: unknown
          request_id?: string | null
          source_name?: string
          user_agent?: string | null
          utm?: Json
          webhook_source_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "webhook_lead_captures_contact_id_fkey"
            columns: ["contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "webhook_lead_captures_lead_id_fkey"
            columns: ["lead_id"]
            isOneToOne: false
            referencedRelation: "crm_leads"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "webhook_lead_captures_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "webhook_lead_captures_webhook_source_id_fkey"
            columns: ["webhook_source_id"]
            isOneToOne: false
            referencedRelation: "webhook_sources"
            referencedColumns: ["id"]
          },
        ]
      }
      webhook_sources: {
        Row: {
          created_at: string
          created_by_user_id: string | null
          default_pipeline_id: string
          default_stage_id: string
          field_map: Json
          id: string
          is_active: boolean
          kind: string
          last_change_actor_kind: string | null
          last_change_at: string | null
          last_received_at: string | null
          name: string
          organization_id: string
          path_token: string
          redirect_to: string | null
          secret_encrypted: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          created_by_user_id?: string | null
          default_pipeline_id: string
          default_stage_id: string
          field_map?: Json
          id?: string
          is_active?: boolean
          kind?: string
          last_change_actor_kind?: string | null
          last_change_at?: string | null
          last_received_at?: string | null
          name: string
          organization_id: string
          path_token: string
          redirect_to?: string | null
          secret_encrypted?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          created_by_user_id?: string | null
          default_pipeline_id?: string
          default_stage_id?: string
          field_map?: Json
          id?: string
          is_active?: boolean
          kind?: string
          last_change_actor_kind?: string | null
          last_change_at?: string | null
          last_received_at?: string | null
          name?: string
          organization_id?: string
          path_token?: string
          redirect_to?: string | null
          secret_encrypted?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "webhook_sources_default_pipeline_id_fkey"
            columns: ["default_pipeline_id"]
            isOneToOne: false
            referencedRelation: "crm_pipelines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "webhook_sources_default_stage_id_fkey"
            columns: ["default_stage_id"]
            isOneToOne: false
            referencedRelation: "crm_stages"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "webhook_sources_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      calendar_google_reconcilable_appointments: {
        Row: Database["public"]["Tables"]["calendar_appointments"]["Row"]
        Relationships: Database["public"]["Tables"]["calendar_appointments"]["Relationships"]
      }
      calendar_selected_external_events: {
        Row: Omit<Database["public"]["Tables"]["calendar_external_events"]["Row"], "starts_at" | "ends_at" | "title"> & { starts_at: string; ends_at: string }
        Relationships: Database["public"]["Tables"]["calendar_external_events"]["Relationships"]
      }

      ai_provider_credentials_safe: {
        Row: {
          api_key_last4: string | null
          created_at: string | null
          created_by: string | null
          id: string | null
          is_active: boolean | null
          label: string | null
          models_available: string[] | null
          organization_id: string | null
          provider: string | null
          updated_at: string | null
          validated_at: string | null
          validation_error: string | null
        }
        Insert: {
          api_key_last4?: string | null
          created_at?: string | null
          created_by?: string | null
          id?: string | null
          is_active?: boolean | null
          label?: string | null
          models_available?: string[] | null
          organization_id?: string | null
          provider?: string | null
          updated_at?: string | null
          validated_at?: string | null
          validation_error?: string | null
        }
        Update: {
          api_key_last4?: string | null
          created_at?: string | null
          created_by?: string | null
          id?: string | null
          is_active?: boolean | null
          label?: string | null
          models_available?: string[] | null
          organization_id?: string | null
          provider?: string | null
          updated_at?: string | null
          validated_at?: string | null
          validation_error?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "ai_provider_credentials_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Functions: {
      fn_channel_routing_claim: {
        Args: {
          p_channel: string
          p_conversation: string
          p_org: string
          p_reason?: string
          p_schedule?: Json
          p_user: string
        }
        Returns: string
      }
      fn_set_channel_routing: {
        Args: {
          p_channel: string
          p_org: string
          p_reset?: boolean
          p_users: string[]
        }
        Returns: Json
      }
      fn_request_channel_routing: {
        Args: { p_conversation: string; p_org: string }
        Returns: undefined
      }
      fn_wake_channel_routing: {
        Args: { p_channel?: string; p_org: string }
        Returns: undefined
      }
      fn_routing_unassigned_notice: {
        Args: { p_conversation: string; p_org: string; p_reason: string }
        Returns: undefined
      }
      fn_reserve_channel_connection: {
        Args: {
          p_display_name?: string
          p_hash: string
          p_key: string
          p_onboarding?: boolean
          p_org: string
        }
        Returns: Json
      }
      fn_extensions_admit_catalog: {
        Args: {
          p_actor: string
          p_digest: string
          p_operation: string
          p_snapshot: Json
        }
        Returns: Json
      }
      fn_extensions_assert_actor: {
        Args: { p_actor: string; p_organization?: string }
        Returns: undefined
      }
      fn_extensions_cancel_install: {
        Args: { p_actor: string; p_operation: string }
        Returns: Json
      }
      fn_extensions_configure: {
        Args: {
          p_actor: string
          p_configuration: Json
          p_enabled: boolean
          p_expected_revision: number
          p_installation: string
          p_operation: string
          p_organization: string
        }
        Returns: Json
      }
      fn_extensions_core_update_in_progress: { Args: never; Returns: boolean }
      fn_extensions_fail_install: {
        Args: { p_actor: string; p_error_code: string; p_operation: string }
        Returns: Json
      }
      fn_extensions_fingerprint: { Args: { p_request: Json }; Returns: string }
      fn_extensions_finish_install: {
        Args: {
          p_actor: string
          p_byte_length: number
          p_document: string
          p_manifest: Json
          p_operation: string
          p_sha256: string
        }
        Returns: Json
      }
      fn_extensions_installation_counts: {
        Args: { p_actor: string }
        Returns: {
          active_organizations: number
          awaiting_reactivation: number
          installation_id: string
        }[]
      }
      fn_extensions_prepare_install: {
        Args: {
          p_actor: string
          p_catalog: string
          p_expected_installation_revision: number
          p_name: string
          p_operation: string
          p_publisher: string
          p_version: string
        }
        Returns: Json
      }
      fn_extensions_remove_installation: {
        Args: {
          p_actor: string
          p_expected_installation_revision: number
          p_installation: string
          p_operation: string
        }
        Returns: Json
      }
      fn_extensions_revert_install: {
        Args: {
          p_actor: string
          p_expected_installation_revision: number
          p_installation: string
          p_operation: string
        }
        Returns: Json
      }
      fn_finish_channel_connection: {
        Args: {
          p_created?: boolean
          p_lease: string
          p_org: string
          p_reason?: string
          p_receipt: string
          p_status: string
        }
        Returns: Json
      }

      fn_google_appointment: { Args: { p_org: string; p_id: string; p_action: string; p_args?: Json }; Returns: Json }
      fn_google_calendar: { Args: { p_org: string; p_id: string; p_action: string; p_args?: Json }; Returns: Json }
      fn_google_calendar_fence: { Args: { p_org: string; p_id: string; p_claim: Json; p_cursor?: Json }; Returns: undefined }
      fn_google_catalog: { Args: { p_org: string; p_connection: string; p_items: Json; p_revision: string }; Returns: undefined }
      fn_google_selection: { Args: { p_org: string; p_revisions: Json; p_sources: string[]; p_destination: string }; Returns: undefined }
      fn_meet_delivery_policy: { Args: { p_org:string; p_job:string; p_worker:string; p_acquired_at:string }; Returns:Json }
      fn_meet_delivery_current: { Args: { p_org:string; p_job:string; p_worker:string; p_acquired_at:string }; Returns:boolean }
      fn_meet_delivery_settle: { Args: { p_org:string; p_job:string; p_worker:string; p_acquired_at:string; p_state:string; p_retry_at?:string|null }; Returns:boolean }
      fn_meet_action: { Args: { p_org:string; p_id:string; p_revision:string; p_request:string|null; p_action:string; p_conversation?:string|null }; Returns:boolean }
      fn_google_resolve: { Args: { p_org: string; p_id: string; p_revision: string; p_local_revision: string; p_etag: string | null; p_choice: string }; Returns: undefined }
      fn_google_counts_for_conflicts: { Args: { p_org: string; p_connection: string; p_calendar: string }; Returns: boolean }
      fn_google_coverage: { Args: { p_org: string; p_owner: string; p_start: string; p_end: string }; Returns: boolean }
      fn_agenda_ocupacao_google_do_dono: {
        Args: { p_org: string; p_owner: string; p_de: string; p_ate: string }
        Returns: { starts_at: string; ends_at: string; transparency: string; status: string; connection_status: string }[]
      }
      fn_agenda_conexoes_google_do_dono: {
        Args: { p_org: string; p_owner: string }
        Returns: { status: string; last_sync_at: string | null }[]
      }
      fn_appointment_change_core: { Args: { p_org: string; p_id: string; p_revision: number; p_patch: Json; p_remote: boolean; p_base: Json }; Returns: Json }

      fn_followup_job_current: { Args: { p_org: string; p_job: string; p_enrollment: string; p_node: string }; Returns: boolean }
      fn_agenda_minutes: { Args: { p_settings: Json; p_key: string; p_default: number }; Returns: number }
      fn_followup_claim_current: { Args: { p_org: string; p_job: string; p_worker: string; p_acquired_at: string }; Returns: boolean }
      fn_appointment_change: { Args: { p_org: string; p_id: string; p_revision: number; p_patch: Json }; Returns: Json }
      fn_appointment_recover: { Args: { p_org: string; p_event: string }; Returns: Json }
      fn_appointment_confirmation_sweep: { Args: { p_limit?: number; p_now?: string }; Returns: number }
      fn_appointment_enrollment_current: { Args: { p_org: string; p_id: string; p_node?: string | null }; Returns: boolean }
      fn_agenda_settings: { Args: { p_org: string; p_config: Json }; Returns: Json }
      fn_colegas_podem_mexer_na_agenda: { Args: { p_org: string }; Returns: boolean }
      fn_definir_colegas_podem_mexer_na_agenda: { Args: { p_org: string; p_ligado: boolean }; Returns: Json }
      fn_definir_cliente_pela_agenda: { Args: { p_ligado: boolean; p_org: string }; Returns: Json }
      fn_followup_patch: { Args: { p_org: string; p_id: string; p_revision: number; p_patch: Json }; Returns: number }
      fn_followup_apply_step: { Args: { p_org: string; p_id: string; p_revision: number; p_patch: Json; p_event: Json }; Returns: number }
      fn_followup_inline_settle: { Args: { p_org: string; p_id: string; p_worker: string; p_done: boolean; p_error?: string | null; p_retry_at?: string | null; p_hold?: boolean; p_acquired_at?: string }; Returns: boolean }
      fn_service_observe_command: { Args: { p_org: string; p_contact: string }; Returns: Json }
      fn_service_event_origin: {
        Args: { p_org: string; p_event: string; p_contact: string; p_session?: string }
        Returns: Json
      }

      fn_service_observe: {
        Args: { p_contact: string; p_org: string }
        Returns: Json
      }
      fn_service_boundary: {
        Args: { p_conversation: string; p_org: string }
        Returns: Json
      }
      fn_service_begin: {
        Args: {
          p_contact: string
          p_observed?: Json
          p_org: string
          p_session?: string
        }
        Returns: Json
      }
      fn_demanda_encerrar: {
        Args: {
          p_actor: string
          p_demanda: string
          p_desfecho: string
          p_expected: number
          p_org: string
        }
        Returns: {
          aberta_em: string
          agent_case_id: string | null
          assunto: string | null
          contact_id: string
          created_at: string
          desfecho: string | null
          dono_kind: string
          dono_user_id: string | null
          encerrada_por: string | null
          estado: string
          fechada_em: string | null
          id: string
          lead_id: string | null
          organization_id: string
          origem: string
          prazo_em: string | null
          proximo_passo: string | null
          proximo_passo_em: string | null
          revision: number
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "demandas"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      fn_service_status: {
        Args: {
          p_conversation: string
          p_expected?: number
          p_org: string
          p_status: string
        }
        Returns: {
          active_agent_set_at: string | null
          active_ai_agent_id: string | null
          active_intent: string | null
          assigned_at: string | null
          assigned_to_user_id: string | null
          assigned_to_user_name: string | null
          assignee_kind: string | null
          awaiting_since: string | null
          bot_silenced_until: string | null
          channel: string
          channel_session_id: string
          contact_id: string
          created_at: string
          current_demanda_id: string | null
          group_chat_id: string | null
          id: string
          is_group: boolean
          last_handoff_at: string | null
          last_handoff_reason: string | null
          last_inbound_at: string | null
          last_message_at: string | null
          last_message_preview: string | null
          last_outbound_at: string | null
          metadata: Json
          organization_id: string
          provider_conversation_id: string | null
          rag_review_status: string | null
          service_closed_at: string | null
          service_revision: number
          service_started_at: string | null
          snooze_until: string | null
          snoozed_at: string | null
          snoozed_by_user_id: string | null
          status: string
          status_changed_at: string
          tags: string[]
          unread_count_for_assignee: number
          updated_at: string
          usable_for_rag: boolean
          usable_for_rag_marked_at: string | null
          usable_for_rag_marked_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "conversations"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      fn_service_inbound: { Args: { p_message: string }; Returns: undefined }
      fn_service_lock: {
        Args: { p_contact: string; p_org: string }
        Returns: undefined
      }
      fn_create_tenant_with_owner: {
        Args: { p_actor: string; p_key: string; p_request: Json; p_hash: string }
        Returns: Json
      }
      fn_accept_team_invite: {
        Args: { p_user: string; p_org: string; p_role: string; p_invited_by: string | null; p_issued_at: string | null; p_invited_at: string; p_interface_settings?: Json }
        Returns: Json
      }

      fn_support_context: { Args: Record<PropertyKey, never>; Returns: Json }
      fn_support_write_allowed: { Args: { p_org: string }; Returns: boolean }
      fn_support_storage_write_allowed: { Args: { p_name: string }; Returns: boolean }
      fn_support_callback_write_allowed: { Args: { p_org: string; p_actor?: string; p_session?: string }; Returns: boolean }
      fn_start_support: { Args: { p_actor: string; p_session: string; p_org: string; p_previous: string | null; p_mode?: string; p_ttl?: number }; Returns: string }
      fn_end_support: { Args: { p_actor: string; p_session: string }; Returns: Json }

      activate_kb_version: {
        Args: { p_agent_id: string; p_version_id: string }
        Returns: undefined
      }
      emit_event: {
        Args: {
          p_entity_id: string
          p_entity_kind: string
          p_event_type: string
          p_metadata?: Json
          p_organization_id?: string
          p_payload?: Json
        }
        Returns: string
      }
      fn_agent_tool_usage: {
        Args: { p_agent_id: string; p_organization_id: string; p_since: string }
        Returns: {
          em_teste: number
          falhas: number
          tool_name: string
          total: number
          ultima_vez: string
        }[]
      }
      fn_agora: { Args: never; Returns: string }
      fn_aplicar_quadro_do_onboarding: {
        Args: {
          p_etapas: Json
          p_nome: string
          p_organization_id: string
          p_pipeline_id: string
          p_slug: string
        }
        Returns: Json
      }
      fn_atrito_jaccard: { Args: { a: string; b: string }; Returns: number }
      fn_atrito_metrics: {
        Args: {
          p_abandono_horas?: number
          p_espera_horas?: number
          p_from: string
          p_org: string
          p_repeticao_min?: number
          p_to: string
        }
        Returns: Json
      }
      fn_attendant_metrics: {
        Args: { p_from: string; p_org: string; p_owner?: string; p_to: string }
        Returns: Json
      }
      fn_buscar_trechos_das_fontes: {
        Args: {
          p_embedding: string
          p_embedding_model?: string
          p_k?: number
          p_organization_id: string
          p_source_ids: string[]
          p_threshold?: number
        }
        Returns: {
          chunk_id: string
          content: string
          knowledge_source_id: string
          metadata: Json
          similarity: number
          source_name: string
        }[]
      }
      fn_can_view_conversation: {
        Args: { p_assigned_to_user_id: string; p_org: string }
        Returns: boolean
      }
      fn_can_view_lead: {
        Args: { p_org: string; p_owner_user_id: string }
        Returns: boolean
      }
      fn_claim_due_followup_enrollments: {
        Args: { p_lease_seconds: number; p_limit: number }
        Returns: {
          agent_id: string | null
          attempts: number
          cancel_reason: string | null
          claimed_until: string | null
          completed_at: string | null
          contact_id: string
          conversation_id: string | null
          current_node_id: string
          id: string
          last_error: string | null
          max_attempts: number
          next_eval_at: string | null
          organization_id: string
          outcome: string | null
          pointer_id: string
          started_at: string
          status: string
          steps_taken: number
          timing_plan: Json | null
          updated_at: string
          version_id: string
        }[]
        SetofOptions: {
          from: "*"
          to: "followup_enrollments"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      fn_configurar_pre_go_live_canal: {
        Args: {
          p_canal: string
          p_modo: string
          p_numeros: string[]
          p_org: string
        }
        Returns: number
      }
      fn_conversation_assign: {
        Args: {
          p_conversation_id: string
          p_enforce_expected?: boolean
          p_expected_assignee?: string
          p_organization_id: string
          p_reason: string
          p_to_user_id: string
        }
        Returns: {
          active_agent_set_at: string | null
          active_ai_agent_id: string | null
          active_intent: string | null
          assigned_at: string | null
          assigned_to_user_id: string | null
          assigned_to_user_name: string | null
          assignee_kind: string | null
          awaiting_since: string | null
          bot_silenced_until: string | null
          channel: string
          channel_session_id: string
          contact_id: string
          created_at: string
          group_chat_id: string | null
          id: string
          is_group: boolean
          last_handoff_at: string | null
          last_handoff_reason: string | null
          last_inbound_at: string | null
          last_message_at: string | null
          last_message_preview: string | null
          last_outbound_at: string | null
          metadata: Json
          organization_id: string
          provider_conversation_id: string | null
          rag_review_status: string | null
          snooze_until: string | null
          snoozed_at: string | null
          snoozed_by_user_id: string | null
          status: string
          status_changed_at: string
          tags: string[]
          unread_count_for_assignee: number
          updated_at: string
          usable_for_rag: boolean
          usable_for_rag_marked_at: string | null
          usable_for_rag_marked_by: string | null
        }[]
        SetofOptions: {
          from: "*"
          to: "conversations"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      fn_decrypt_oauth: { Args: { ciphertext: string }; Returns: string }
      fn_definir_logo_da_organizacao: {
        Args: { p_actor: string; p_org: string; p_path: string }
        Returns: number
      }
      fn_definir_marca_da_organizacao: {
        Args: { p_actor: string; p_marca: Json; p_org: string }
        Returns: number
      }
      fn_encrypt_oauth: { Args: { plaintext: string }; Returns: string }
      fn_estampar_atribuicao_de_anuncio: {
        Args: {
          p_contact: string
          p_metadata: Json
          p_org: string
          p_platform: string
        }
        Returns: undefined
      }
      fn_expurgar_auditoria_vencida: {
        Args: { p_limite?: number; p_retencao_dias?: number }
        Returns: number
      }
      fn_expurgar_espelho_da_agenda: {
        Args: { p_limite?: number; p_retencao_dias?: number }
        Returns: number
      }
      fn_expurgar_nonces_de_oauth: {
        Args: { p_dias: number; p_lote?: number }
        Returns: number
      }
      fn_gasto_de_ia_do_mes: { Args: { p_org: string }; Returns: number }
      fn_is_platform_admin: { Args: never; Returns: boolean }
      fn_lgpd_anonymize_contact: {
        Args: { p_contact_id: string; p_organization_id: string }
        Returns: Json
      }
      fn_lgpd_cascade_redact_contact: {
        Args: {
          p_contact_id: string
          p_organization_id: string
          p_request_id: string
        }
        Returns: Json
      }
      fn_log_event: {
        Args: {
          p_event_type: string
          p_organization_id: string
          p_payload?: Json
        }
        Returns: string
      }
      fn_mark_conversation_message: {
        Args: {
          p_at: string
          p_conv: string
          p_direction: string
          p_preview: string
        }
        Returns: undefined
      }
      fn_member_role_in_org: {
        Args: { p_org: string; p_user: string }
        Returns: string
      }
      fn_mesclar_contatos: {
        Args: {
          p_contato_principal: string
          p_contatos_secundarios: string[]
          p_organization_id: string
        }
        Returns: Json
      }
      fn_mover_leads_em_lote: {
        Args: {
          p_lead_ids: string[]
          p_lost_reason?: string
          p_organization_id: string
          p_stage_id: string
        }
        Returns: {
          from_stage_id: string
          lead_id: string
          pipeline_id: string
        }[]
      }
      fn_podar_fila_de_jobs: {
        Args: { p_limite?: number; p_retencao_dias?: number }
        Returns: number
      }
      fn_reply_action: {
        Args: {
          p_org: string;
          p_id: string;
          p_revision: string;
          p_action: string;
          p_body?: string | null;
          p_feedback?: string | null;
        };
        Returns: string;
      }
      fn_agent_legacy_notice: {
        Args: {p_org:string;p_agent:string;p_code:string;p_title:string;p_body:string};
        Returns:boolean;
      }
      fn_reply_record_receipt: {
        Args: {p_org:string;p_job:string;p_worker:string;p_acquired_at:string;p_message:string;p_external:string|null;p_echo_ids?:string[]};
        Returns:Json;
      }
      fn_reply_receipt_policy: {
        Args: { p_org: string; p_job: string; p_worker: string; p_acquired_at: string };
        Returns: Json;
      }
      fn_reply_delivery_policy: {
        Args: { p_org: string; p_job: string; p_worker: string; p_acquired_at: string };
        Returns: Json;
      }
      fn_reply_prepare: {
        Args: { p_org: string; p_job: string; p_worker: string; p_acquired_at: string };
        Returns: boolean;
      }
      fn_publish_ai_agent_version: {
        Args: { p_agent_id: string; p_org_id: string; p_version_id: string; p_platform_credential_verified?:boolean; p_expected_provenance?:string|null }
        Returns: {
          agent_id: string
          previous_version_id: string
          published_at: string
          version_id: string
        }[]
      }
      fn_publish_followup_flow_version: {
        Args: {
          p_created_by: string
          p_graph: Json
          p_org: string
          p_pointer: string
        }
        Returns: string
      }
      fn_role_at_least: {
        Args: { p_min: string; p_org: string }
        Returns: boolean
      }
      fn_semear_tipos_de_agendamento: {
        Args: { p_organization_id: string }
        Returns: number
      }
      fn_upsert_wa_contact: {
        Args: {
          p_chat_id: string
          p_kind: string
          p_lid: string
          p_notify: string
          p_org: string
          p_phone: string
        }
        Returns: string
      }
      fn_upsert_wa_conversation: {
        Args: { p_contact: string; p_org: string; p_session: string }
        Returns: string
      }
      fn_user_org_ids: { Args: never; Returns: string[] }
      fn_user_role_in: { Args: { p_org: string }; Returns: number }
      fn_user_role_in_org: { Args: { p_org: string }; Returns: string }
      midpoint: { Args: { p_next: number; p_prev: number }; Returns: number }
      retrieve_top_k_chunks: {
        Args: {
          p_embedding: string
          p_k?: number
          p_kb_version_id: string
          p_organization_id: string
          p_threshold?: number
        }
        Returns: {
          chunk_id: string
          content: string
          knowledge_source_id: string
          metadata: Json
          similarity: number
        }[]
      }
      show_limit: { Args: never; Returns: number }
      show_trgm: { Args: { "": string }; Returns: string[] }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  storage: {
    Tables: {
      buckets: {
        Row: {
          allowed_mime_types: string[] | null
          avif_autodetection: boolean | null
          created_at: string | null
          file_size_limit: number | null
          id: string
          name: string
          owner: string | null
          owner_id: string | null
          public: boolean | null
          type: Database["storage"]["Enums"]["buckettype"]
          updated_at: string | null
          versioning_status: string
        }
        Insert: {
          allowed_mime_types?: string[] | null
          avif_autodetection?: boolean | null
          created_at?: string | null
          file_size_limit?: number | null
          id: string
          name: string
          owner?: string | null
          owner_id?: string | null
          public?: boolean | null
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string | null
          versioning_status?: string
        }
        Update: {
          allowed_mime_types?: string[] | null
          avif_autodetection?: boolean | null
          created_at?: string | null
          file_size_limit?: number | null
          id?: string
          name?: string
          owner?: string | null
          owner_id?: string | null
          public?: boolean | null
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string | null
          versioning_status?: string
        }
        Relationships: []
      }
      buckets_analytics: {
        Row: {
          created_at: string
          deleted_at: string | null
          format: string
          id: string
          name: string
          type: Database["storage"]["Enums"]["buckettype"]
          updated_at: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          format?: string
          id?: string
          name: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          format?: string
          id?: string
          name?: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Relationships: []
      }
      buckets_vectors: {
        Row: {
          created_at: string
          id: string
          type: Database["storage"]["Enums"]["buckettype"]
          updated_at: string
        }
        Insert: {
          created_at?: string
          id: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Update: {
          created_at?: string
          id?: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Relationships: []
      }
      migrations: {
        Row: {
          executed_at: string | null
          hash: string
          id: number
          name: string
        }
        Insert: {
          executed_at?: string | null
          hash: string
          id: number
          name: string
        }
        Update: {
          executed_at?: string | null
          hash?: string
          id?: number
          name?: string
        }
        Relationships: []
      }
      objects: {
        Row: {
          archived_at: string | null
          bucket_id: string | null
          created_at: string | null
          id: string
          is_delete_marker: boolean
          is_versioned: boolean
          last_accessed_at: string | null
          metadata: Json | null
          name: string | null
          owner: string | null
          owner_id: string | null
          path_tokens: string[] | null
          updated_at: string | null
          user_metadata: Json | null
          version: string | null
        }
        Insert: {
          archived_at?: string | null
          bucket_id?: string | null
          created_at?: string | null
          id?: string
          is_delete_marker?: boolean
          is_versioned?: boolean
          last_accessed_at?: string | null
          metadata?: Json | null
          name?: string | null
          owner?: string | null
          owner_id?: string | null
          path_tokens?: string[] | null
          updated_at?: string | null
          user_metadata?: Json | null
          version?: string | null
        }
        Update: {
          archived_at?: string | null
          bucket_id?: string | null
          created_at?: string | null
          id?: string
          is_delete_marker?: boolean
          is_versioned?: boolean
          last_accessed_at?: string | null
          metadata?: Json | null
          name?: string | null
          owner?: string | null
          owner_id?: string | null
          path_tokens?: string[] | null
          updated_at?: string | null
          user_metadata?: Json | null
          version?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "objects_bucketId_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets"
            referencedColumns: ["id"]
          },
        ]
      }
      s3_multipart_uploads: {
        Row: {
          bucket_id: string
          created_at: string
          id: string
          in_progress_size: number
          key: string
          metadata: Json | null
          owner_id: string | null
          upload_signature: string
          user_metadata: Json | null
          version: string
        }
        Insert: {
          bucket_id: string
          created_at?: string
          id: string
          in_progress_size?: number
          key: string
          metadata?: Json | null
          owner_id?: string | null
          upload_signature: string
          user_metadata?: Json | null
          version: string
        }
        Update: {
          bucket_id?: string
          created_at?: string
          id?: string
          in_progress_size?: number
          key?: string
          metadata?: Json | null
          owner_id?: string | null
          upload_signature?: string
          user_metadata?: Json | null
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "s3_multipart_uploads_bucket_id_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets"
            referencedColumns: ["id"]
          },
        ]
      }
      s3_multipart_uploads_parts: {
        Row: {
          bucket_id: string
          created_at: string
          etag: string
          id: string
          key: string
          owner_id: string | null
          part_number: number
          size: number
          upload_id: string
          version: string
        }
        Insert: {
          bucket_id: string
          created_at?: string
          etag: string
          id?: string
          key: string
          owner_id?: string | null
          part_number: number
          size?: number
          upload_id: string
          version: string
        }
        Update: {
          bucket_id?: string
          created_at?: string
          etag?: string
          id?: string
          key?: string
          owner_id?: string | null
          part_number?: number
          size?: number
          upload_id?: string
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "s3_multipart_uploads_parts_bucket_id_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "s3_multipart_uploads_parts_upload_id_fkey"
            columns: ["upload_id"]
            isOneToOne: false
            referencedRelation: "s3_multipart_uploads"
            referencedColumns: ["id"]
          },
        ]
      }
      vector_indexes: {
        Row: {
          bucket_id: string
          created_at: string
          data_type: string
          dimension: number
          distance_metric: string
          id: string
          metadata_configuration: Json | null
          name: string
          updated_at: string
        }
        Insert: {
          bucket_id: string
          created_at?: string
          data_type: string
          dimension: number
          distance_metric: string
          id?: string
          metadata_configuration?: Json | null
          name: string
          updated_at?: string
        }
        Update: {
          bucket_id?: string
          created_at?: string
          data_type?: string
          dimension?: number
          distance_metric?: string
          id?: string
          metadata_configuration?: Json | null
          name?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "vector_indexes_bucket_id_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets_vectors"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      allow_any_operation: {
        Args: { expected_operations: string[] }
        Returns: boolean
      }
      allow_only_operation: {
        Args: { expected_operation: string }
        Returns: boolean
      }
      can_insert_object: {
        Args: { bucketid: string; metadata: Json; name: string; owner: string }
        Returns: undefined
      }
      extension: { Args: { name: string }; Returns: string }
      filename: { Args: { name: string }; Returns: string }
      foldername: { Args: { name: string }; Returns: string[] }
      get_common_prefix: {
        Args: { p_delimiter: string; p_key: string; p_prefix: string }
        Returns: string
      }
      get_size_by_bucket: {
        Args: never
        Returns: {
          bucket_id: string
          size: number
        }[]
      }
      list_multipart_uploads_with_delimiter: {
        Args: {
          bucket_id: string
          delimiter_param: string
          max_keys?: number
          next_key_token?: string
          next_upload_token?: string
          prefix_param: string
        }
        Returns: {
          created_at: string
          id: string
          key: string
        }[]
      }
      list_objects_with_delimiter: {
        Args: {
          _bucket_id: string
          delimiter_param: string
          max_keys?: number
          next_token?: string
          prefix_param: string
          sort_order?: string
          start_after?: string
        }
        Returns: {
          created_at: string
          id: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
      operation: { Args: never; Returns: string }
      search: {
        Args: {
          bucketname: string
          levels?: number
          limits?: number
          offsets?: number
          prefix: string
          search?: string
          sortcolumn?: string
          sortorder?: string
        }
        Returns: {
          created_at: string
          id: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
      search_by_timestamp: {
        Args: {
          p_bucket_id: string
          p_level: number
          p_limit: number
          p_prefix: string
          p_sort_column: string
          p_sort_column_after: string
          p_sort_order: string
          p_start_after: string
        }
        Returns: {
          created_at: string
          id: string
          key: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
      search_v2: {
        Args: {
          bucket_name: string
          levels?: number
          limits?: number
          prefix: string
          sort_column?: string
          sort_column_after?: string
          sort_order?: string
          start_after?: string
        }
        Returns: {
          created_at: string
          id: string
          key: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
    }
    Enums: {
      buckettype: "STANDARD" | "ANALYTICS" | "VECTOR"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  graphql_public: {
    Enums: {},
  },
  public: {
    Enums: {},
  },
  storage: {
    Enums: {
      buckettype: ["STANDARD", "ANALYTICS", "VECTOR"],
    },
  },
} as const

