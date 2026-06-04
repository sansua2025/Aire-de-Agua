export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.4"
  }
  public: {
    Tables: {
      ad_creative_embeddings: {
        Row: {
          ad_id: string
          ad_name: string | null
          audiencia: string | null
          campaign_name: string | null
          created_at: string | null
          cta: string | null
          embedding: string | null
          id: string
          modelo: string | null
          objetivo: string | null
          texto_fuente: string
          updated_at: string | null
        }
        Insert: {
          ad_id: string
          ad_name?: string | null
          audiencia?: string | null
          campaign_name?: string | null
          created_at?: string | null
          cta?: string | null
          embedding?: string | null
          id?: string
          modelo?: string | null
          objetivo?: string | null
          texto_fuente: string
          updated_at?: string | null
        }
        Update: {
          ad_id?: string
          ad_name?: string | null
          audiencia?: string | null
          campaign_name?: string | null
          created_at?: string | null
          cta?: string | null
          embedding?: string | null
          id?: string
          modelo?: string | null
          objetivo?: string | null
          texto_fuente?: string
          updated_at?: string | null
        }
        Relationships: []
      }
      ad_creative_taxonomy: {
        Row: {
          ad_id: string
          ad_name: string | null
          angulo: string | null
          audiencia: string | null
          confidence: string | null
          formato: string | null
          parsed_at: string | null
          prenda: string | null
        }
        Insert: {
          ad_id: string
          ad_name?: string | null
          angulo?: string | null
          audiencia?: string | null
          confidence?: string | null
          formato?: string | null
          parsed_at?: string | null
          prenda?: string | null
        }
        Update: {
          ad_id?: string
          ad_name?: string | null
          angulo?: string | null
          audiencia?: string | null
          confidence?: string | null
          formato?: string | null
          parsed_at?: string | null
          prenda?: string | null
        }
        Relationships: []
      }
      ad_performance_history: {
        Row: {
          ai_raw_json: Json | null
          avg_cpc: number | null
          avg_ctr: number | null
          avg_roas_margin: number | null
          created_at: string | null
          id: number
          main_action: string | null
          main_insight: string | null
          score: string | null
          top_angulo: string | null
          top_formato: string | null
          top_prenda: string | null
          total_purchases: number | null
          total_spend: number | null
          week_end: string
          week_start: string
        }
        Insert: {
          ai_raw_json?: Json | null
          avg_cpc?: number | null
          avg_ctr?: number | null
          avg_roas_margin?: number | null
          created_at?: string | null
          id?: number
          main_action?: string | null
          main_insight?: string | null
          score?: string | null
          top_angulo?: string | null
          top_formato?: string | null
          top_prenda?: string | null
          total_purchases?: number | null
          total_spend?: number | null
          week_end: string
          week_start: string
        }
        Update: {
          ai_raw_json?: Json | null
          avg_cpc?: number | null
          avg_ctr?: number | null
          avg_roas_margin?: number | null
          created_at?: string | null
          id?: number
          main_action?: string | null
          main_insight?: string | null
          score?: string | null
          top_angulo?: string | null
          top_formato?: string | null
          top_prenda?: string | null
          total_purchases?: number | null
          total_spend?: number | null
          week_end?: string
          week_start?: string
        }
        Relationships: []
      }
      ai_analysis_log: {
        Row: {
          created_at: string | null
          duracion_segundos: number | null
          error_mensaje: string | null
          estado: string | null
          id: string
          insights_actualizados: number | null
          insights_creados: number | null
          learnings_creados: number | null
          periodo_fin: string | null
          periodo_inicio: string | null
          resumen: string | null
          segmentos_actualizados: number | null
          tipo: string
          tokens_usados: number | null
        }
        Insert: {
          created_at?: string | null
          duracion_segundos?: number | null
          error_mensaje?: string | null
          estado?: string | null
          id?: string
          insights_actualizados?: number | null
          insights_creados?: number | null
          learnings_creados?: number | null
          periodo_fin?: string | null
          periodo_inicio?: string | null
          resumen?: string | null
          segmentos_actualizados?: number | null
          tipo: string
          tokens_usados?: number | null
        }
        Update: {
          created_at?: string | null
          duracion_segundos?: number | null
          error_mensaje?: string | null
          estado?: string | null
          id?: string
          insights_actualizados?: number | null
          insights_creados?: number | null
          learnings_creados?: number | null
          periodo_fin?: string | null
          periodo_inicio?: string | null
          resumen?: string | null
          segmentos_actualizados?: number | null
          tipo?: string
          tokens_usados?: number | null
        }
        Relationships: []
      }
      amplitude_daily_metrics: {
        Row: {
          agrega_carrito: number | null
          aov: number | null
          compras: number | null
          created_at: string | null
          cvr_carrito_checkout: number | null
          cvr_checkout_compra: number | null
          cvr_total: number | null
          cvr_vista_carrito: number | null
          duracion_sesion_avg: number | null
          fecha: string
          id: string
          inicia_checkout: number | null
          pageviews: number | null
          paginas_por_sesion: number | null
          revenue: number | null
          sesiones: number | null
          tasa_rebote: number | null
          usuarios_activos: number | null
          usuarios_nuevos: number | null
          vistas_producto: number | null
        }
        Insert: {
          agrega_carrito?: number | null
          aov?: number | null
          compras?: number | null
          created_at?: string | null
          cvr_carrito_checkout?: number | null
          cvr_checkout_compra?: number | null
          cvr_total?: number | null
          cvr_vista_carrito?: number | null
          duracion_sesion_avg?: number | null
          fecha: string
          id?: string
          inicia_checkout?: number | null
          pageviews?: number | null
          paginas_por_sesion?: number | null
          revenue?: number | null
          sesiones?: number | null
          tasa_rebote?: number | null
          usuarios_activos?: number | null
          usuarios_nuevos?: number | null
          vistas_producto?: number | null
        }
        Update: {
          agrega_carrito?: number | null
          aov?: number | null
          compras?: number | null
          created_at?: string | null
          cvr_carrito_checkout?: number | null
          cvr_checkout_compra?: number | null
          cvr_total?: number | null
          cvr_vista_carrito?: number | null
          duracion_sesion_avg?: number | null
          fecha?: string
          id?: string
          inicia_checkout?: number | null
          pageviews?: number | null
          paginas_por_sesion?: number | null
          revenue?: number | null
          sesiones?: number | null
          tasa_rebote?: number | null
          usuarios_activos?: number | null
          usuarios_nuevos?: number | null
          vistas_producto?: number | null
        }
        Relationships: []
      }
      amplitude_top_content: {
        Row: {
          created_at: string | null
          entidad_id: string | null
          id: string
          nombre: string | null
          posicion_ranking: number | null
          semana_inicio: string
          tasa_conversion: number | null
          tipo: string | null
          usuarios_unicos: number | null
          vistas: number | null
        }
        Insert: {
          created_at?: string | null
          entidad_id?: string | null
          id?: string
          nombre?: string | null
          posicion_ranking?: number | null
          semana_inicio: string
          tasa_conversion?: number | null
          tipo?: string | null
          usuarios_unicos?: number | null
          vistas?: number | null
        }
        Update: {
          created_at?: string | null
          entidad_id?: string | null
          id?: string
          nombre?: string | null
          posicion_ranking?: number | null
          semana_inicio?: string
          tasa_conversion?: number | null
          tipo?: string | null
          usuarios_unicos?: number | null
          vistas?: number | null
        }
        Relationships: []
      }
      audience_segments: {
        Row: {
          accion_klaviyo: string | null
          accion_meta: string | null
          activo: boolean | null
          canal_preferido: string | null
          categoria_preferida: string | null
          copy_angle: string | null
          created_at: string | null
          creative_style: string | null
          criterios: Json
          cvr_remarketing: number | null
          descripcion: string | null
          frecuencia_compra_dias: number | null
          id: string
          ltv_promedio: number | null
          mejor_dia_envio: string | null
          mejor_hora_envio: number | null
          nombre: string
          open_rate_email: number | null
          talla_frecuente: string | null
          total_clientes: number | null
          ultima_actualizacion: string | null
        }
        Insert: {
          accion_klaviyo?: string | null
          accion_meta?: string | null
          activo?: boolean | null
          canal_preferido?: string | null
          categoria_preferida?: string | null
          copy_angle?: string | null
          created_at?: string | null
          creative_style?: string | null
          criterios: Json
          cvr_remarketing?: number | null
          descripcion?: string | null
          frecuencia_compra_dias?: number | null
          id?: string
          ltv_promedio?: number | null
          mejor_dia_envio?: string | null
          mejor_hora_envio?: number | null
          nombre: string
          open_rate_email?: number | null
          talla_frecuente?: string | null
          total_clientes?: number | null
          ultima_actualizacion?: string | null
        }
        Update: {
          accion_klaviyo?: string | null
          accion_meta?: string | null
          activo?: boolean | null
          canal_preferido?: string | null
          categoria_preferida?: string | null
          copy_angle?: string | null
          created_at?: string | null
          creative_style?: string | null
          criterios?: Json
          cvr_remarketing?: number | null
          descripcion?: string | null
          frecuencia_compra_dias?: number | null
          id?: string
          ltv_promedio?: number | null
          mejor_dia_envio?: string | null
          mejor_hora_envio?: number | null
          nombre?: string
          open_rate_email?: number | null
          talla_frecuente?: string | null
          total_clientes?: number | null
          ultima_actualizacion?: string | null
        }
        Relationships: []
      }
      brand_knowledge: {
        Row: {
          activo: boolean | null
          categoria: string
          contenido: string
          created_at: string | null
          drive_file_id: string | null
          embedding: string | null
          fuente: string | null
          id: string
          titulo: string
          updated_at: string | null
          version: number | null
        }
        Insert: {
          activo?: boolean | null
          categoria: string
          contenido: string
          created_at?: string | null
          drive_file_id?: string | null
          embedding?: string | null
          fuente?: string | null
          id?: string
          titulo: string
          updated_at?: string | null
          version?: number | null
        }
        Update: {
          activo?: boolean | null
          categoria?: string
          contenido?: string
          created_at?: string | null
          drive_file_id?: string | null
          embedding?: string | null
          fuente?: string | null
          id?: string
          titulo?: string
          updated_at?: string | null
          version?: number | null
        }
        Relationships: []
      }
      clientes: {
        Row: {
          acepta_marketing: boolean | null
          apellido: string | null
          canal_origen: string | null
          ciudad: string | null
          colores_frecuentes: string[] | null
          created_at: string | null
          departamento: string | null
          email: string | null
          id: string
          last_synced_at: string | null
          ltv: number | null
          nombre: string | null
          notas: string | null
          pais: string | null
          primera_compra_at: string | null
          segmento: string | null
          shopify_created_at: string | null
          shopify_customer_id: string | null
          tallas_frecuentes: string[] | null
          telefono: string | null
          total_gastado: number | null
          total_pedidos: number | null
          ultima_compra_at: string | null
          updated_at: string | null
        }
        Insert: {
          acepta_marketing?: boolean | null
          apellido?: string | null
          canal_origen?: string | null
          ciudad?: string | null
          colores_frecuentes?: string[] | null
          created_at?: string | null
          departamento?: string | null
          email?: string | null
          id?: string
          last_synced_at?: string | null
          ltv?: number | null
          nombre?: string | null
          notas?: string | null
          pais?: string | null
          primera_compra_at?: string | null
          segmento?: string | null
          shopify_created_at?: string | null
          shopify_customer_id?: string | null
          tallas_frecuentes?: string[] | null
          telefono?: string | null
          total_gastado?: number | null
          total_pedidos?: number | null
          ultima_compra_at?: string | null
          updated_at?: string | null
        }
        Update: {
          acepta_marketing?: boolean | null
          apellido?: string | null
          canal_origen?: string | null
          ciudad?: string | null
          colores_frecuentes?: string[] | null
          created_at?: string | null
          departamento?: string | null
          email?: string | null
          id?: string
          last_synced_at?: string | null
          ltv?: number | null
          nombre?: string | null
          notas?: string | null
          pais?: string | null
          primera_compra_at?: string | null
          segmento?: string | null
          shopify_created_at?: string | null
          shopify_customer_id?: string | null
          tallas_frecuentes?: string[] | null
          telefono?: string | null
          total_gastado?: number | null
          total_pedidos?: number | null
          ultima_compra_at?: string | null
          updated_at?: string | null
        }
        Relationships: []
      }
      cogs_variantes_shopify: {
        Row: {
          fetched_at: string
          fuente: string
          product_status: string | null
          product_title: string | null
          shopify_inventory_item_id: string | null
          shopify_product_id: string
          shopify_variant_id: string
          sku: string | null
          unit_cost: number | null
          unit_cost_currency: string | null
          updated_at: string
          variant_title: string | null
        }
        Insert: {
          fetched_at?: string
          fuente?: string
          product_status?: string | null
          product_title?: string | null
          shopify_inventory_item_id?: string | null
          shopify_product_id: string
          shopify_variant_id: string
          sku?: string | null
          unit_cost?: number | null
          unit_cost_currency?: string | null
          updated_at?: string
          variant_title?: string | null
        }
        Update: {
          fetched_at?: string
          fuente?: string
          product_status?: string | null
          product_title?: string | null
          shopify_inventory_item_id?: string | null
          shopify_product_id?: string
          shopify_variant_id?: string
          sku?: string | null
          unit_cost?: number | null
          unit_cost_currency?: string | null
          updated_at?: string
          variant_title?: string | null
        }
        Relationships: []
      }
      creative_assets: {
        Row: {
          activo: boolean | null
          angulo: string | null
          clics_total: number | null
          coleccion: string | null
          compras_total: number | null
          created_at: string | null
          ctr_promedio: number | null
          drive_file_id: string | null
          emocion: string | null
          fondo: string | null
          formato: string | null
          gasto_total: number | null
          id: string
          impresiones_total: number | null
          modelo: boolean | null
          nombre: string
          prenda: string | null
          roas_promedio: number | null
          score_rendimiento: number | null
          temporada: string | null
          tipo: string | null
          updated_at: string | null
          url_preview: string | null
        }
        Insert: {
          activo?: boolean | null
          angulo?: string | null
          clics_total?: number | null
          coleccion?: string | null
          compras_total?: number | null
          created_at?: string | null
          ctr_promedio?: number | null
          drive_file_id?: string | null
          emocion?: string | null
          fondo?: string | null
          formato?: string | null
          gasto_total?: number | null
          id?: string
          impresiones_total?: number | null
          modelo?: boolean | null
          nombre: string
          prenda?: string | null
          roas_promedio?: number | null
          score_rendimiento?: number | null
          temporada?: string | null
          tipo?: string | null
          updated_at?: string | null
          url_preview?: string | null
        }
        Update: {
          activo?: boolean | null
          angulo?: string | null
          clics_total?: number | null
          coleccion?: string | null
          compras_total?: number | null
          created_at?: string | null
          ctr_promedio?: number | null
          drive_file_id?: string | null
          emocion?: string | null
          fondo?: string | null
          formato?: string | null
          gasto_total?: number | null
          id?: string
          impresiones_total?: number | null
          modelo?: boolean | null
          nombre?: string
          prenda?: string | null
          roas_promedio?: number | null
          score_rendimiento?: number | null
          temporada?: string | null
          tipo?: string | null
          updated_at?: string | null
          url_preview?: string | null
        }
        Relationships: []
      }
      creative_learnings: {
        Row: {
          canal: string | null
          conclusion: string | null
          created_at: string | null
          ctr_promedio: number | null
          cvr_promedio: number | null
          elemento: string
          engagement_promedio: number | null
          id: string
          indice_rendimiento: number | null
          muestra_anuncios: number | null
          objetivo: string | null
          periodo_fin: string | null
          periodo_inicio: string | null
          roas_promedio: number | null
          score_confianza: number | null
          segmento_audiencia: string | null
          updated_at: string | null
          valor: string
          vigente: boolean | null
        }
        Insert: {
          canal?: string | null
          conclusion?: string | null
          created_at?: string | null
          ctr_promedio?: number | null
          cvr_promedio?: number | null
          elemento: string
          engagement_promedio?: number | null
          id?: string
          indice_rendimiento?: number | null
          muestra_anuncios?: number | null
          objetivo?: string | null
          periodo_fin?: string | null
          periodo_inicio?: string | null
          roas_promedio?: number | null
          score_confianza?: number | null
          segmento_audiencia?: string | null
          updated_at?: string | null
          valor: string
          vigente?: boolean | null
        }
        Update: {
          canal?: string | null
          conclusion?: string | null
          created_at?: string | null
          ctr_promedio?: number | null
          cvr_promedio?: number | null
          elemento?: string
          engagement_promedio?: number | null
          id?: string
          indice_rendimiento?: number | null
          muestra_anuncios?: number | null
          objetivo?: string | null
          periodo_fin?: string | null
          periodo_inicio?: string | null
          roas_promedio?: number | null
          score_confianza?: number | null
          segmento_audiencia?: string | null
          updated_at?: string | null
          valor?: string
          vigente?: boolean | null
        }
        Relationships: []
      }
      creative_visuals: {
        Row: {
          asset_id: string
          asset_type: string
          created_at: string | null
          description: string
          extras: Json | null
          match_method: string | null
          match_score: number | null
          modelo: string
          origen: string
          producto_id: string | null
          resolved_url: string | null
          updated_at: string | null
        }
        Insert: {
          asset_id: string
          asset_type: string
          created_at?: string | null
          description: string
          extras?: Json | null
          match_method?: string | null
          match_score?: number | null
          modelo?: string
          origen?: string
          producto_id?: string | null
          resolved_url?: string | null
          updated_at?: string | null
        }
        Update: {
          asset_id?: string
          asset_type?: string
          created_at?: string | null
          description?: string
          extras?: Json | null
          match_method?: string | null
          match_score?: number | null
          modelo?: string
          origen?: string
          producto_id?: string | null
          resolved_url?: string | null
          updated_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "creative_visuals_producto_id_fkey"
            columns: ["producto_id"]
            isOneToOne: false
            referencedRelation: "productos"
            referencedColumns: ["id"]
          },
        ]
      }
      insights: {
        Row: {
          accion_evaluada: string | null
          accion_notas: string | null
          accion_sugerida: string | null
          accion_tomada: boolean | null
          created_at: string | null
          delta_pct: number | null
          descripcion: string
          dominio: string
          embedding: string | null
          id: string
          metrica_clave: string | null
          periodo_fin: string | null
          periodo_inicio: string | null
          score_confianza: number | null
          tipo: string
          titulo: string
          ultima_confirmacion: string | null
          updated_at: string | null
          valor_observado: number | null
          valor_referencia: number | null
          veces_confirmado: number | null
          vigente: boolean | null
        }
        Insert: {
          accion_evaluada?: string | null
          accion_notas?: string | null
          accion_sugerida?: string | null
          accion_tomada?: boolean | null
          created_at?: string | null
          delta_pct?: number | null
          descripcion: string
          dominio: string
          embedding?: string | null
          id?: string
          metrica_clave?: string | null
          periodo_fin?: string | null
          periodo_inicio?: string | null
          score_confianza?: number | null
          tipo: string
          titulo: string
          ultima_confirmacion?: string | null
          updated_at?: string | null
          valor_observado?: number | null
          valor_referencia?: number | null
          veces_confirmado?: number | null
          vigente?: boolean | null
        }
        Update: {
          accion_evaluada?: string | null
          accion_notas?: string | null
          accion_sugerida?: string | null
          accion_tomada?: boolean | null
          created_at?: string | null
          delta_pct?: number | null
          descripcion?: string
          dominio?: string
          embedding?: string | null
          id?: string
          metrica_clave?: string | null
          periodo_fin?: string | null
          periodo_inicio?: string | null
          score_confianza?: number | null
          tipo?: string
          titulo?: string
          ultima_confirmacion?: string | null
          updated_at?: string | null
          valor_observado?: number | null
          valor_referencia?: number | null
          veces_confirmado?: number | null
          vigente?: boolean | null
        }
        Relationships: []
      }
      instagram_post_embeddings: {
        Row: {
          created_at: string | null
          embedding: string | null
          id: string
          meta_post_id: string
          modelo: string | null
          plataforma: string | null
          texto_fuente: string
          tipo: string | null
          updated_at: string | null
        }
        Insert: {
          created_at?: string | null
          embedding?: string | null
          id?: string
          meta_post_id: string
          modelo?: string | null
          plataforma?: string | null
          texto_fuente: string
          tipo?: string | null
          updated_at?: string | null
        }
        Update: {
          created_at?: string | null
          embedding?: string | null
          id?: string
          meta_post_id?: string
          modelo?: string | null
          plataforma?: string | null
          texto_fuente?: string
          tipo?: string | null
          updated_at?: string | null
        }
        Relationships: []
      }
      instagram_profile_daily: {
        Row: {
          created_at: string | null
          fecha: string
          followers_new: number | null
          followers_total: number | null
          id: string
          impressions: number | null
          profile_views: number | null
          reach: number | null
          reach_per_follower: number | null
          source: string | null
          updated_at: string | null
          website_taps: number | null
        }
        Insert: {
          created_at?: string | null
          fecha: string
          followers_new?: number | null
          followers_total?: number | null
          id?: string
          impressions?: number | null
          profile_views?: number | null
          reach?: number | null
          reach_per_follower?: number | null
          source?: string | null
          updated_at?: string | null
          website_taps?: number | null
        }
        Update: {
          created_at?: string | null
          fecha?: string
          followers_new?: number | null
          followers_total?: number | null
          id?: string
          impressions?: number | null
          profile_views?: number | null
          reach?: number | null
          reach_per_follower?: number | null
          source?: string | null
          updated_at?: string | null
          website_taps?: number | null
        }
        Relationships: []
      }
      inventario: {
        Row: {
          cantidad: number
          cantidad_disponible: number | null
          cantidad_reservada: number | null
          id: string
          last_synced_at: string | null
          shopify_inventory_item_id: string | null
          ubicacion_id: string
          updated_at: string | null
          variante_id: string
        }
        Insert: {
          cantidad?: number
          cantidad_disponible?: number | null
          cantidad_reservada?: number | null
          id?: string
          last_synced_at?: string | null
          shopify_inventory_item_id?: string | null
          ubicacion_id: string
          updated_at?: string | null
          variante_id: string
        }
        Update: {
          cantidad?: number
          cantidad_disponible?: number | null
          cantidad_reservada?: number | null
          id?: string
          last_synced_at?: string | null
          shopify_inventory_item_id?: string | null
          ubicacion_id?: string
          updated_at?: string | null
          variante_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "inventario_ubicacion_id_fkey"
            columns: ["ubicacion_id"]
            isOneToOne: false
            referencedRelation: "ubicaciones"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventario_variante_id_fkey"
            columns: ["variante_id"]
            isOneToOne: false
            referencedRelation: "v_huerfanos_pendientes"
            referencedColumns: ["match_sku_variante_id"]
          },
          {
            foreignKeyName: "inventario_variante_id_fkey"
            columns: ["variante_id"]
            isOneToOne: false
            referencedRelation: "v_huerfanos_pendientes"
            referencedColumns: ["match_titulo_variante_id"]
          },
          {
            foreignKeyName: "inventario_variante_id_fkey"
            columns: ["variante_id"]
            isOneToOne: false
            referencedRelation: "variantes"
            referencedColumns: ["id"]
          },
        ]
      }
      klaviyo_campaigns: {
        Row: {
          abiertos: number | null
          asunto: string | null
          bajas: number | null
          click_rate: number | null
          clics: number | null
          conversion_rate: number | null
          conversiones: number | null
          created_at: string | null
          entregados: number | null
          enviado_at: string | null
          enviados: number | null
          estado: string | null
          id: string
          ingresos: number | null
          klaviyo_campaign_id: string
          last_synced_at: string | null
          nombre: string
          open_rate: number | null
          preview_text: string | null
          segmento_nombre: string | null
          tipo: string | null
        }
        Insert: {
          abiertos?: number | null
          asunto?: string | null
          bajas?: number | null
          click_rate?: number | null
          clics?: number | null
          conversion_rate?: number | null
          conversiones?: number | null
          created_at?: string | null
          entregados?: number | null
          enviado_at?: string | null
          enviados?: number | null
          estado?: string | null
          id?: string
          ingresos?: number | null
          klaviyo_campaign_id: string
          last_synced_at?: string | null
          nombre: string
          open_rate?: number | null
          preview_text?: string | null
          segmento_nombre?: string | null
          tipo?: string | null
        }
        Update: {
          abiertos?: number | null
          asunto?: string | null
          bajas?: number | null
          click_rate?: number | null
          clics?: number | null
          conversion_rate?: number | null
          conversiones?: number | null
          created_at?: string | null
          entregados?: number | null
          enviado_at?: string | null
          enviados?: number | null
          estado?: string | null
          id?: string
          ingresos?: number | null
          klaviyo_campaign_id?: string
          last_synced_at?: string | null
          nombre?: string
          open_rate?: number | null
          preview_text?: string | null
          segmento_nombre?: string | null
          tipo?: string | null
        }
        Relationships: []
      }
      klaviyo_flow_daily: {
        Row: {
          abiertos: number | null
          bajas: number | null
          click_rate: number | null
          clics: number | null
          conversion_rate: number | null
          conversiones: number | null
          created_at: string | null
          entregados: number | null
          enviados: number | null
          estado: string | null
          fecha: string
          id: string
          ingresos: number | null
          klaviyo_flow_id: string
          last_synced_at: string | null
          nombre: string
          open_rate: number | null
          trigger_type: string | null
        }
        Insert: {
          abiertos?: number | null
          bajas?: number | null
          click_rate?: number | null
          clics?: number | null
          conversion_rate?: number | null
          conversiones?: number | null
          created_at?: string | null
          entregados?: number | null
          enviados?: number | null
          estado?: string | null
          fecha: string
          id?: string
          ingresos?: number | null
          klaviyo_flow_id: string
          last_synced_at?: string | null
          nombre: string
          open_rate?: number | null
          trigger_type?: string | null
        }
        Update: {
          abiertos?: number | null
          bajas?: number | null
          click_rate?: number | null
          clics?: number | null
          conversion_rate?: number | null
          conversiones?: number | null
          created_at?: string | null
          entregados?: number | null
          enviados?: number | null
          estado?: string | null
          fecha?: string
          id?: string
          ingresos?: number | null
          klaviyo_flow_id?: string
          last_synced_at?: string | null
          nombre?: string
          open_rate?: number | null
          trigger_type?: string | null
        }
        Relationships: []
      }
      klaviyo_profiles: {
        Row: {
          churn_risk: string | null
          cliente_id: string | null
          created_at: string | null
          email: string | null
          id: string
          klaviyo_profile_id: string
          last_synced_at: string | null
          predicciones_ltv: number | null
          prob_recompra: number | null
          segmentos: string[] | null
          suscrito: boolean | null
          ultimo_clic: string | null
          ultimo_email_abierto: string | null
        }
        Insert: {
          churn_risk?: string | null
          cliente_id?: string | null
          created_at?: string | null
          email?: string | null
          id?: string
          klaviyo_profile_id: string
          last_synced_at?: string | null
          predicciones_ltv?: number | null
          prob_recompra?: number | null
          segmentos?: string[] | null
          suscrito?: boolean | null
          ultimo_clic?: string | null
          ultimo_email_abierto?: string | null
        }
        Update: {
          churn_risk?: string | null
          cliente_id?: string | null
          created_at?: string | null
          email?: string | null
          id?: string
          klaviyo_profile_id?: string
          last_synced_at?: string | null
          predicciones_ltv?: number | null
          prob_recompra?: number | null
          segmentos?: string[] | null
          suscrito?: boolean | null
          ultimo_clic?: string | null
          ultimo_email_abierto?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "klaviyo_profiles_cliente_id_fkey"
            columns: ["cliente_id"]
            isOneToOne: false
            referencedRelation: "clientes"
            referencedColumns: ["id"]
          },
        ]
      }
      meta_ads_performance: {
        Row: {
          ad_id: string
          ad_name: string | null
          adset_id: string | null
          adset_name: string | null
          agrega_carrito: number | null
          alcance: number | null
          asset_feed_bodies: string[] | null
          asset_feed_descriptions: string[] | null
          asset_feed_titles: string[] | null
          audiencia: string | null
          body_copy: string | null
          campaign_id: string | null
          campaign_name: string | null
          clics: number | null
          clics_link: number | null
          compras: number | null
          cpa: number | null
          cpc: number | null
          created_at: string | null
          creative_asset_id: string | null
          cta: string | null
          ctr: number | null
          es_pagado: boolean | null
          fecha: string
          gasto: number | null
          headline: string | null
          id: string
          image_hash: string | null
          image_url: string | null
          impresiones: number | null
          inicia_checkout: number | null
          link_description: string | null
          meta_raw_json: Json | null
          objetivo: string | null
          optimization_goal: string | null
          roas: number | null
          targeting_raw: Json | null
          targeting_summary: string | null
          valor_compras: number | null
          video_id: string | null
          vistas_contenido: number | null
        }
        Insert: {
          ad_id: string
          ad_name?: string | null
          adset_id?: string | null
          adset_name?: string | null
          agrega_carrito?: number | null
          alcance?: number | null
          asset_feed_bodies?: string[] | null
          asset_feed_descriptions?: string[] | null
          asset_feed_titles?: string[] | null
          audiencia?: string | null
          body_copy?: string | null
          campaign_id?: string | null
          campaign_name?: string | null
          clics?: number | null
          clics_link?: number | null
          compras?: number | null
          cpa?: number | null
          cpc?: number | null
          created_at?: string | null
          creative_asset_id?: string | null
          cta?: string | null
          ctr?: number | null
          es_pagado?: boolean | null
          fecha: string
          gasto?: number | null
          headline?: string | null
          id?: string
          image_hash?: string | null
          image_url?: string | null
          impresiones?: number | null
          inicia_checkout?: number | null
          link_description?: string | null
          meta_raw_json?: Json | null
          objetivo?: string | null
          optimization_goal?: string | null
          roas?: number | null
          targeting_raw?: Json | null
          targeting_summary?: string | null
          valor_compras?: number | null
          video_id?: string | null
          vistas_contenido?: number | null
        }
        Update: {
          ad_id?: string
          ad_name?: string | null
          adset_id?: string | null
          adset_name?: string | null
          agrega_carrito?: number | null
          alcance?: number | null
          asset_feed_bodies?: string[] | null
          asset_feed_descriptions?: string[] | null
          asset_feed_titles?: string[] | null
          audiencia?: string | null
          body_copy?: string | null
          campaign_id?: string | null
          campaign_name?: string | null
          clics?: number | null
          clics_link?: number | null
          compras?: number | null
          cpa?: number | null
          cpc?: number | null
          created_at?: string | null
          creative_asset_id?: string | null
          cta?: string | null
          ctr?: number | null
          es_pagado?: boolean | null
          fecha?: string
          gasto?: number | null
          headline?: string | null
          id?: string
          image_hash?: string | null
          image_url?: string | null
          impresiones?: number | null
          inicia_checkout?: number | null
          link_description?: string | null
          meta_raw_json?: Json | null
          objetivo?: string | null
          optimization_goal?: string | null
          roas?: number | null
          targeting_raw?: Json | null
          targeting_summary?: string | null
          valor_compras?: number | null
          video_id?: string | null
          vistas_contenido?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "meta_ads_performance_creative_asset_id_fkey"
            columns: ["creative_asset_id"]
            isOneToOne: false
            referencedRelation: "creative_assets"
            referencedColumns: ["id"]
          },
        ]
      }
      meta_organic_posts: {
        Row: {
          alcance: number | null
          caption: string | null
          clics_link: number | null
          clics_perfil: number | null
          comentarios: number | null
          compartidos: number | null
          created_at: string | null
          creative_asset_id: string | null
          engagement_rate: number | null
          extras_json: Json | null
          fecha_publicacion: string | null
          guardados: number | null
          hashtags: string[] | null
          id: string
          image_url: string | null
          impresiones: number | null
          last_synced_at: string | null
          likes: number | null
          meta_post_id: string
          plataforma: string | null
          post_shortcode: string | null
          post_url: string | null
          tipo: string | null
          upsert_key: string
          visualizaciones: number | null
        }
        Insert: {
          alcance?: number | null
          caption?: string | null
          clics_link?: number | null
          clics_perfil?: number | null
          comentarios?: number | null
          compartidos?: number | null
          created_at?: string | null
          creative_asset_id?: string | null
          engagement_rate?: number | null
          extras_json?: Json | null
          fecha_publicacion?: string | null
          guardados?: number | null
          hashtags?: string[] | null
          id?: string
          image_url?: string | null
          impresiones?: number | null
          last_synced_at?: string | null
          likes?: number | null
          meta_post_id: string
          plataforma?: string | null
          post_shortcode?: string | null
          post_url?: string | null
          tipo?: string | null
          upsert_key: string
          visualizaciones?: number | null
        }
        Update: {
          alcance?: number | null
          caption?: string | null
          clics_link?: number | null
          clics_perfil?: number | null
          comentarios?: number | null
          compartidos?: number | null
          created_at?: string | null
          creative_asset_id?: string | null
          engagement_rate?: number | null
          extras_json?: Json | null
          fecha_publicacion?: string | null
          guardados?: number | null
          hashtags?: string[] | null
          id?: string
          image_url?: string | null
          impresiones?: number | null
          last_synced_at?: string | null
          likes?: number | null
          meta_post_id?: string
          plataforma?: string | null
          post_shortcode?: string | null
          post_url?: string | null
          tipo?: string | null
          upsert_key?: string
          visualizaciones?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "meta_organic_posts_creative_asset_id_fkey"
            columns: ["creative_asset_id"]
            isOneToOne: false
            referencedRelation: "creative_assets"
            referencedColumns: ["id"]
          },
        ]
      }
      product_embeddings: {
        Row: {
          coleccion: string | null
          created_at: string | null
          descripcion_visual: string | null
          embedding: string | null
          embedding_visual: string | null
          id: string
          modelo: string | null
          producto_id: string
          tags: string[] | null
          temporada: string | null
          texto_fuente: string
          tipo: string | null
          updated_at: string | null
        }
        Insert: {
          coleccion?: string | null
          created_at?: string | null
          descripcion_visual?: string | null
          embedding?: string | null
          embedding_visual?: string | null
          id?: string
          modelo?: string | null
          producto_id: string
          tags?: string[] | null
          temporada?: string | null
          texto_fuente: string
          tipo?: string | null
          updated_at?: string | null
        }
        Update: {
          coleccion?: string | null
          created_at?: string | null
          descripcion_visual?: string | null
          embedding?: string | null
          embedding_visual?: string | null
          id?: string
          modelo?: string | null
          producto_id?: string
          tags?: string[] | null
          temporada?: string | null
          texto_fuente?: string
          tipo?: string | null
          updated_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "product_embeddings_producto_id_fkey"
            columns: ["producto_id"]
            isOneToOne: true
            referencedRelation: "productos"
            referencedColumns: ["id"]
          },
        ]
      }
      product_images: {
        Row: {
          alt: string | null
          created_at: string | null
          descripcion_visual: string | null
          embedding_visual: string | null
          height: number | null
          id: string
          last_synced_at: string | null
          posicion: number | null
          procesado: boolean | null
          producto_id: string
          shopify_image_id: string
          shopify_product_id: string | null
          updated_at: string | null
          url: string
          width: number | null
        }
        Insert: {
          alt?: string | null
          created_at?: string | null
          descripcion_visual?: string | null
          embedding_visual?: string | null
          height?: number | null
          id?: string
          last_synced_at?: string | null
          posicion?: number | null
          procesado?: boolean | null
          producto_id: string
          shopify_image_id: string
          shopify_product_id?: string | null
          updated_at?: string | null
          url: string
          width?: number | null
        }
        Update: {
          alt?: string | null
          created_at?: string | null
          descripcion_visual?: string | null
          embedding_visual?: string | null
          height?: number | null
          id?: string
          last_synced_at?: string | null
          posicion?: number | null
          procesado?: boolean | null
          producto_id?: string
          shopify_image_id?: string
          shopify_product_id?: string | null
          updated_at?: string | null
          url?: string
          width?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "product_images_producto_id_fkey"
            columns: ["producto_id"]
            isOneToOne: false
            referencedRelation: "productos"
            referencedColumns: ["id"]
          },
        ]
      }
      productos: {
        Row: {
          coleccion: string | null
          created_at: string | null
          descripcion: string | null
          estado: string | null
          genero: string | null
          handle: string | null
          id: string
          last_synced_at: string | null
          material: string | null
          ocasion: string[] | null
          shopify_created_at: string | null
          shopify_product_id: string
          shopify_updated_at: string | null
          tags: string[] | null
          temporada: string | null
          tipo: string | null
          titulo: string
          updated_at: string | null
        }
        Insert: {
          coleccion?: string | null
          created_at?: string | null
          descripcion?: string | null
          estado?: string | null
          genero?: string | null
          handle?: string | null
          id?: string
          last_synced_at?: string | null
          material?: string | null
          ocasion?: string[] | null
          shopify_created_at?: string | null
          shopify_product_id: string
          shopify_updated_at?: string | null
          tags?: string[] | null
          temporada?: string | null
          tipo?: string | null
          titulo: string
          updated_at?: string | null
        }
        Update: {
          coleccion?: string | null
          created_at?: string | null
          descripcion?: string | null
          estado?: string | null
          genero?: string | null
          handle?: string | null
          id?: string
          last_synced_at?: string | null
          material?: string | null
          ocasion?: string[] | null
          shopify_created_at?: string | null
          shopify_product_id?: string
          shopify_updated_at?: string | null
          tags?: string[] | null
          temporada?: string | null
          tipo?: string | null
          titulo?: string
          updated_at?: string | null
        }
        Relationships: []
      }
      productos_cogs: {
        Row: {
          activo: boolean | null
          cogs: number | null
          created_at: string | null
          id: number
          last_synced_at: string | null
          margen_pct: number | null
          nombre_producto: string | null
          precio_venta: number | null
          prenda: string | null
          shopify_product_id: string | null
          sku: string | null
        }
        Insert: {
          activo?: boolean | null
          cogs?: number | null
          created_at?: string | null
          id?: number
          last_synced_at?: string | null
          margen_pct?: number | null
          nombre_producto?: string | null
          precio_venta?: number | null
          prenda?: string | null
          shopify_product_id?: string | null
          sku?: string | null
        }
        Update: {
          activo?: boolean | null
          cogs?: number | null
          created_at?: string | null
          id?: number
          last_synced_at?: string | null
          margen_pct?: number | null
          nombre_producto?: string | null
          precio_venta?: number | null
          prenda?: string | null
          shopify_product_id?: string | null
          sku?: string | null
        }
        Relationships: []
      }
      reconciliacion_venta_items_huerfanos: {
        Row: {
          aplicado: boolean
          aplicado_at: string | null
          confianza: string
          created_at: string
          estrategia: string
          huerfano_producto_titulo: string | null
          huerfano_sku: string | null
          huerfano_variante_titulo: string | null
          id: string
          justificacion: string
          revertido: boolean
          revertido_at: string | null
          revertido_motivo: string | null
          updated_at: string
          variante_id_asignada: string | null
          venta_item_id: string
        }
        Insert: {
          aplicado?: boolean
          aplicado_at?: string | null
          confianza: string
          created_at?: string
          estrategia: string
          huerfano_producto_titulo?: string | null
          huerfano_sku?: string | null
          huerfano_variante_titulo?: string | null
          id?: string
          justificacion: string
          revertido?: boolean
          revertido_at?: string | null
          revertido_motivo?: string | null
          updated_at?: string
          variante_id_asignada?: string | null
          venta_item_id: string
        }
        Update: {
          aplicado?: boolean
          aplicado_at?: string | null
          confianza?: string
          created_at?: string
          estrategia?: string
          huerfano_producto_titulo?: string | null
          huerfano_sku?: string | null
          huerfano_variante_titulo?: string | null
          id?: string
          justificacion?: string
          revertido?: boolean
          revertido_at?: string | null
          revertido_motivo?: string | null
          updated_at?: string
          variante_id_asignada?: string | null
          venta_item_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "reconciliacion_venta_items_huerfanos_variante_id_asignada_fkey"
            columns: ["variante_id_asignada"]
            isOneToOne: false
            referencedRelation: "v_huerfanos_pendientes"
            referencedColumns: ["match_sku_variante_id"]
          },
          {
            foreignKeyName: "reconciliacion_venta_items_huerfanos_variante_id_asignada_fkey"
            columns: ["variante_id_asignada"]
            isOneToOne: false
            referencedRelation: "v_huerfanos_pendientes"
            referencedColumns: ["match_titulo_variante_id"]
          },
          {
            foreignKeyName: "reconciliacion_venta_items_huerfanos_variante_id_asignada_fkey"
            columns: ["variante_id_asignada"]
            isOneToOne: false
            referencedRelation: "variantes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reconciliacion_venta_items_huerfanos_venta_item_id_fkey"
            columns: ["venta_item_id"]
            isOneToOne: false
            referencedRelation: "venta_items"
            referencedColumns: ["id"]
          },
        ]
      }
      shopify_customer_journeys: {
        Row: {
          created_at: string
          customer_order_index: number | null
          days_to_conversion: number | null
          first_visit_at: string | null
          first_visit_campaign: string | null
          first_visit_content: string | null
          first_visit_landing: string | null
          first_visit_marketing_event_id: string | null
          first_visit_medium: string | null
          first_visit_referrer: string | null
          first_visit_source: string | null
          first_visit_source_type: string | null
          first_visit_term: string | null
          last_synced_at: string
          last_visit_at: string | null
          last_visit_campaign: string | null
          last_visit_content: string | null
          last_visit_landing: string | null
          last_visit_medium: string | null
          last_visit_referrer: string | null
          last_visit_source: string | null
          last_visit_source_type: string | null
          last_visit_term: string | null
          moments_count: number | null
          moments_precision: string | null
          raw_payload: Json | null
          ready: boolean
          shopify_order_id: string
          venta_id: string
        }
        Insert: {
          created_at?: string
          customer_order_index?: number | null
          days_to_conversion?: number | null
          first_visit_at?: string | null
          first_visit_campaign?: string | null
          first_visit_content?: string | null
          first_visit_landing?: string | null
          first_visit_marketing_event_id?: string | null
          first_visit_medium?: string | null
          first_visit_referrer?: string | null
          first_visit_source?: string | null
          first_visit_source_type?: string | null
          first_visit_term?: string | null
          last_synced_at?: string
          last_visit_at?: string | null
          last_visit_campaign?: string | null
          last_visit_content?: string | null
          last_visit_landing?: string | null
          last_visit_medium?: string | null
          last_visit_referrer?: string | null
          last_visit_source?: string | null
          last_visit_source_type?: string | null
          last_visit_term?: string | null
          moments_count?: number | null
          moments_precision?: string | null
          raw_payload?: Json | null
          ready?: boolean
          shopify_order_id: string
          venta_id: string
        }
        Update: {
          created_at?: string
          customer_order_index?: number | null
          days_to_conversion?: number | null
          first_visit_at?: string | null
          first_visit_campaign?: string | null
          first_visit_content?: string | null
          first_visit_landing?: string | null
          first_visit_marketing_event_id?: string | null
          first_visit_medium?: string | null
          first_visit_referrer?: string | null
          first_visit_source?: string | null
          first_visit_source_type?: string | null
          first_visit_term?: string | null
          last_synced_at?: string
          last_visit_at?: string | null
          last_visit_campaign?: string | null
          last_visit_content?: string | null
          last_visit_landing?: string | null
          last_visit_medium?: string | null
          last_visit_referrer?: string | null
          last_visit_source?: string | null
          last_visit_source_type?: string | null
          last_visit_term?: string | null
          moments_count?: number | null
          moments_precision?: string | null
          raw_payload?: Json | null
          ready?: boolean
          shopify_order_id?: string
          venta_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "shopify_customer_journeys_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: true
            referencedRelation: "v_ventas_atribuidas"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "shopify_customer_journeys_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: true
            referencedRelation: "ventas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shopify_customer_journeys_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: true
            referencedRelation: "ventas_atribucion_normalizada"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "shopify_customer_journeys_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: true
            referencedRelation: "vista_atribucion_web"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "shopify_customer_journeys_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: true
            referencedRelation: "vista_atribucion_web_con_margen"
            referencedColumns: ["venta_id"]
          },
        ]
      }
      shopify_customer_moments: {
        Row: {
          created_at: string
          id: string
          landing_page: string | null
          marketing_event_id: string | null
          occurred_at: string
          posicion: number
          referrer_url: string | null
          shopify_visit_id: string
          source_type: string | null
          utm_campaign: string | null
          utm_content: string | null
          utm_medium: string | null
          utm_source: string | null
          utm_term: string | null
          venta_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          landing_page?: string | null
          marketing_event_id?: string | null
          occurred_at: string
          posicion: number
          referrer_url?: string | null
          shopify_visit_id: string
          source_type?: string | null
          utm_campaign?: string | null
          utm_content?: string | null
          utm_medium?: string | null
          utm_source?: string | null
          utm_term?: string | null
          venta_id: string
        }
        Update: {
          created_at?: string
          id?: string
          landing_page?: string | null
          marketing_event_id?: string | null
          occurred_at?: string
          posicion?: number
          referrer_url?: string | null
          shopify_visit_id?: string
          source_type?: string | null
          utm_campaign?: string | null
          utm_content?: string | null
          utm_medium?: string | null
          utm_source?: string | null
          utm_term?: string | null
          venta_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "shopify_customer_moments_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "v_ventas_atribuidas"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "shopify_customer_moments_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "ventas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shopify_customer_moments_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "ventas_atribucion_normalizada"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "shopify_customer_moments_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "vista_atribucion_web"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "shopify_customer_moments_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "vista_atribucion_web_con_margen"
            referencedColumns: ["venta_id"]
          },
        ]
      }
      shopify_discount_attributions: {
        Row: {
          created_at: string
          discount_amount: number | null
          discount_code: string | null
          discount_type: string | null
          id: string
          is_first_order: boolean | null
          price_rule_id: string | null
          venta_id: string
        }
        Insert: {
          created_at?: string
          discount_amount?: number | null
          discount_code?: string | null
          discount_type?: string | null
          id?: string
          is_first_order?: boolean | null
          price_rule_id?: string | null
          venta_id: string
        }
        Update: {
          created_at?: string
          discount_amount?: number | null
          discount_code?: string | null
          discount_type?: string | null
          id?: string
          is_first_order?: boolean | null
          price_rule_id?: string | null
          venta_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "shopify_discount_attributions_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "v_ventas_atribuidas"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "shopify_discount_attributions_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "ventas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shopify_discount_attributions_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "ventas_atribucion_normalizada"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "shopify_discount_attributions_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "vista_atribucion_web"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "shopify_discount_attributions_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "vista_atribucion_web_con_margen"
            referencedColumns: ["venta_id"]
          },
        ]
      }
      shopify_marketing_events: {
        Row: {
          app_name: string | null
          created_at: string
          description: string | null
          ended_at: string | null
          id: string
          last_synced_at: string
          manage_url: string | null
          marketing_channel_type: string | null
          preview_url: string | null
          raw_payload: Json | null
          remote_id: string | null
          scheduled_to_end_at: string | null
          source_and_medium: string | null
          started_at: string | null
          type: string | null
          utm_campaign: string | null
          utm_medium: string | null
          utm_source: string | null
        }
        Insert: {
          app_name?: string | null
          created_at?: string
          description?: string | null
          ended_at?: string | null
          id: string
          last_synced_at?: string
          manage_url?: string | null
          marketing_channel_type?: string | null
          preview_url?: string | null
          raw_payload?: Json | null
          remote_id?: string | null
          scheduled_to_end_at?: string | null
          source_and_medium?: string | null
          started_at?: string | null
          type?: string | null
          utm_campaign?: string | null
          utm_medium?: string | null
          utm_source?: string | null
        }
        Update: {
          app_name?: string | null
          created_at?: string
          description?: string | null
          ended_at?: string | null
          id?: string
          last_synced_at?: string
          manage_url?: string | null
          marketing_channel_type?: string | null
          preview_url?: string | null
          raw_payload?: Json | null
          remote_id?: string | null
          scheduled_to_end_at?: string | null
          source_and_medium?: string | null
          started_at?: string | null
          type?: string | null
          utm_campaign?: string | null
          utm_medium?: string | null
          utm_source?: string | null
        }
        Relationships: []
      }
      shopify_segments_membership: {
        Row: {
          cliente_id: string
          fecha_snapshot: string
          segment_id: string
          segment_name: string | null
        }
        Insert: {
          cliente_id: string
          fecha_snapshot: string
          segment_id: string
          segment_name?: string | null
        }
        Update: {
          cliente_id?: string
          fecha_snapshot?: string
          segment_id?: string
          segment_name?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "shopify_segments_membership_cliente_id_fkey"
            columns: ["cliente_id"]
            isOneToOne: false
            referencedRelation: "clientes"
            referencedColumns: ["id"]
          },
        ]
      }
      sync_log: {
        Row: {
          created_at: string | null
          duracion_ms: number | null
          entidad: string
          entidad_id: string | null
          error_mensaje: string | null
          estado: string | null
          evento: string
          id: string
          payload_hash: string | null
        }
        Insert: {
          created_at?: string | null
          duracion_ms?: number | null
          entidad: string
          entidad_id?: string | null
          error_mensaje?: string | null
          estado?: string | null
          evento: string
          id?: string
          payload_hash?: string | null
        }
        Update: {
          created_at?: string | null
          duracion_ms?: number | null
          entidad?: string
          entidad_id?: string | null
          error_mensaje?: string | null
          estado?: string | null
          evento?: string
          id?: string
          payload_hash?: string | null
        }
        Relationships: []
      }
      ubicaciones: {
        Row: {
          activo: boolean | null
          created_at: string | null
          id: string
          nombre: string
          shopify_location_id: string | null
          tipo: string | null
        }
        Insert: {
          activo?: boolean | null
          created_at?: string | null
          id?: string
          nombre: string
          shopify_location_id?: string | null
          tipo?: string | null
        }
        Update: {
          activo?: boolean | null
          created_at?: string | null
          id?: string
          nombre?: string
          shopify_location_id?: string | null
          tipo?: string | null
        }
        Relationships: []
      }
      variantes: {
        Row: {
          codigo_barras: string | null
          cogs: number | null
          color: string | null
          created_at: string | null
          estado: string | null
          estampado: string | null
          id: string
          last_synced_at: string | null
          margen_pct: number | null
          peso_gramos: number | null
          precio: number | null
          precio_comparacion: number | null
          producto_id: string
          shopify_inventory_item_id: string | null
          shopify_product_id: string
          shopify_updated_at: string | null
          shopify_variant_id: string
          sku: string | null
          talla: string | null
          titulo: string | null
        }
        Insert: {
          codigo_barras?: string | null
          cogs?: number | null
          color?: string | null
          created_at?: string | null
          estado?: string | null
          estampado?: string | null
          id?: string
          last_synced_at?: string | null
          margen_pct?: number | null
          peso_gramos?: number | null
          precio?: number | null
          precio_comparacion?: number | null
          producto_id: string
          shopify_inventory_item_id?: string | null
          shopify_product_id: string
          shopify_updated_at?: string | null
          shopify_variant_id: string
          sku?: string | null
          talla?: string | null
          titulo?: string | null
        }
        Update: {
          codigo_barras?: string | null
          cogs?: number | null
          color?: string | null
          created_at?: string | null
          estado?: string | null
          estampado?: string | null
          id?: string
          last_synced_at?: string | null
          margen_pct?: number | null
          peso_gramos?: number | null
          precio?: number | null
          precio_comparacion?: number | null
          producto_id?: string
          shopify_inventory_item_id?: string | null
          shopify_product_id?: string
          shopify_updated_at?: string | null
          shopify_variant_id?: string
          sku?: string | null
          talla?: string | null
          titulo?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "variantes_producto_id_fkey"
            columns: ["producto_id"]
            isOneToOne: false
            referencedRelation: "productos"
            referencedColumns: ["id"]
          },
        ]
      }
      venta_items: {
        Row: {
          cantidad: number
          cogs_unitario: number | null
          descuento: number | null
          id: string
          margen_linea: number | null
          precio_unitario: number
          producto_titulo: string | null
          shopify_line_item_id: string | null
          sku: string | null
          total_linea: number | null
          variante_id: string | null
          variante_titulo: string | null
          venta_id: string
        }
        Insert: {
          cantidad?: number
          cogs_unitario?: number | null
          descuento?: number | null
          id?: string
          margen_linea?: number | null
          precio_unitario: number
          producto_titulo?: string | null
          shopify_line_item_id?: string | null
          sku?: string | null
          total_linea?: number | null
          variante_id?: string | null
          variante_titulo?: string | null
          venta_id: string
        }
        Update: {
          cantidad?: number
          cogs_unitario?: number | null
          descuento?: number | null
          id?: string
          margen_linea?: number | null
          precio_unitario?: number
          producto_titulo?: string | null
          shopify_line_item_id?: string | null
          sku?: string | null
          total_linea?: number | null
          variante_id?: string | null
          variante_titulo?: string | null
          venta_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "venta_items_variante_id_fkey"
            columns: ["variante_id"]
            isOneToOne: false
            referencedRelation: "v_huerfanos_pendientes"
            referencedColumns: ["match_sku_variante_id"]
          },
          {
            foreignKeyName: "venta_items_variante_id_fkey"
            columns: ["variante_id"]
            isOneToOne: false
            referencedRelation: "v_huerfanos_pendientes"
            referencedColumns: ["match_titulo_variante_id"]
          },
          {
            foreignKeyName: "venta_items_variante_id_fkey"
            columns: ["variante_id"]
            isOneToOne: false
            referencedRelation: "variantes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "venta_items_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "v_ventas_atribuidas"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "venta_items_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "ventas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "venta_items_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "ventas_atribucion_normalizada"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "venta_items_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "vista_atribucion_web"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "venta_items_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "vista_atribucion_web_con_margen"
            referencedColumns: ["venta_id"]
          },
        ]
      }
      ventas: {
        Row: {
          canal: string
          cliente_email: string | null
          cliente_id: string | null
          cliente_nombre: string | null
          costo_envio: number | null
          created_at: string | null
          cuotas: number | null
          descuento: number | null
          estado_orden: string | null
          estado_pago: string | null
          id: string
          impuesto: number | null
          last_synced_at: string | null
          metodo_pago: string | null
          moneda: string | null
          notas: string | null
          numero_orden: string | null
          ordered_at: string
          shopify_order_id: string | null
          subtotal: number
          tipo_pago: string | null
          total: number
          ubicacion_id: string | null
          utm_campaign: string | null
          utm_content: string | null
          utm_medium: string | null
          utm_source: string | null
          utm_term: string | null
        }
        Insert: {
          canal: string
          cliente_email?: string | null
          cliente_id?: string | null
          cliente_nombre?: string | null
          costo_envio?: number | null
          created_at?: string | null
          cuotas?: number | null
          descuento?: number | null
          estado_orden?: string | null
          estado_pago?: string | null
          id?: string
          impuesto?: number | null
          last_synced_at?: string | null
          metodo_pago?: string | null
          moneda?: string | null
          notas?: string | null
          numero_orden?: string | null
          ordered_at: string
          shopify_order_id?: string | null
          subtotal?: number
          tipo_pago?: string | null
          total?: number
          ubicacion_id?: string | null
          utm_campaign?: string | null
          utm_content?: string | null
          utm_medium?: string | null
          utm_source?: string | null
          utm_term?: string | null
        }
        Update: {
          canal?: string
          cliente_email?: string | null
          cliente_id?: string | null
          cliente_nombre?: string | null
          costo_envio?: number | null
          created_at?: string | null
          cuotas?: number | null
          descuento?: number | null
          estado_orden?: string | null
          estado_pago?: string | null
          id?: string
          impuesto?: number | null
          last_synced_at?: string | null
          metodo_pago?: string | null
          moneda?: string | null
          notas?: string | null
          numero_orden?: string | null
          ordered_at?: string
          shopify_order_id?: string | null
          subtotal?: number
          tipo_pago?: string | null
          total?: number
          ubicacion_id?: string | null
          utm_campaign?: string | null
          utm_content?: string | null
          utm_medium?: string | null
          utm_source?: string | null
          utm_term?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "ventas_cliente_id_fkey"
            columns: ["cliente_id"]
            isOneToOne: false
            referencedRelation: "clientes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ventas_ubicacion_id_fkey"
            columns: ["ubicacion_id"]
            isOneToOne: false
            referencedRelation: "ubicaciones"
            referencedColumns: ["id"]
          },
        ]
      }
      ventas_offline: {
        Row: {
          cliente_nombre: string | null
          cliente_telefono: string | null
          creado_por: string | null
          created_at: string | null
          evento: string | null
          fecha: string
          id: string
          metodo_pago: string | null
          notas: string | null
          procesado: boolean | null
          total: number
          ubicacion_id: string | null
          venta_id: string | null
        }
        Insert: {
          cliente_nombre?: string | null
          cliente_telefono?: string | null
          creado_por?: string | null
          created_at?: string | null
          evento?: string | null
          fecha?: string
          id?: string
          metodo_pago?: string | null
          notas?: string | null
          procesado?: boolean | null
          total: number
          ubicacion_id?: string | null
          venta_id?: string | null
        }
        Update: {
          cliente_nombre?: string | null
          cliente_telefono?: string | null
          creado_por?: string | null
          created_at?: string | null
          evento?: string | null
          fecha?: string
          id?: string
          metodo_pago?: string | null
          notas?: string | null
          procesado?: boolean | null
          total?: number
          ubicacion_id?: string | null
          venta_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "ventas_offline_ubicacion_id_fkey"
            columns: ["ubicacion_id"]
            isOneToOne: false
            referencedRelation: "ubicaciones"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ventas_offline_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "v_ventas_atribuidas"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "ventas_offline_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "ventas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ventas_offline_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "ventas_atribucion_normalizada"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "ventas_offline_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "vista_atribucion_web"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "ventas_offline_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "vista_atribucion_web_con_margen"
            referencedColumns: ["venta_id"]
          },
        ]
      }
      webhook_e2_huerfanos_log: {
        Row: {
          cantidad: number | null
          created_at: string
          detected_at: string
          id: string
          notas: string | null
          numero_orden: number | null
          precio_unitario: number | null
          producto_titulo: string | null
          requiere_retry: boolean
          requiere_revision_manual: boolean
          resuelto: boolean
          resuelto_at: string | null
          resuelto_por: string | null
          retry_count: number
          shopify_line_item_id: string | null
          shopify_variant_id: string | null
          sku: string | null
          ultimo_retry_at: string | null
          updated_at: string
          variante_titulo: string | null
          venta_id: string
          venta_item_id: string
        }
        Insert: {
          cantidad?: number | null
          created_at?: string
          detected_at?: string
          id?: string
          notas?: string | null
          numero_orden?: number | null
          precio_unitario?: number | null
          producto_titulo?: string | null
          requiere_retry?: boolean
          requiere_revision_manual?: boolean
          resuelto?: boolean
          resuelto_at?: string | null
          resuelto_por?: string | null
          retry_count?: number
          shopify_line_item_id?: string | null
          shopify_variant_id?: string | null
          sku?: string | null
          ultimo_retry_at?: string | null
          updated_at?: string
          variante_titulo?: string | null
          venta_id: string
          venta_item_id: string
        }
        Update: {
          cantidad?: number | null
          created_at?: string
          detected_at?: string
          id?: string
          notas?: string | null
          numero_orden?: number | null
          precio_unitario?: number | null
          producto_titulo?: string | null
          requiere_retry?: boolean
          requiere_revision_manual?: boolean
          resuelto?: boolean
          resuelto_at?: string | null
          resuelto_por?: string | null
          retry_count?: number
          shopify_line_item_id?: string | null
          shopify_variant_id?: string | null
          sku?: string | null
          ultimo_retry_at?: string | null
          updated_at?: string
          variante_titulo?: string | null
          venta_id?: string
          venta_item_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "webhook_e2_huerfanos_log_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "v_ventas_atribuidas"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "webhook_e2_huerfanos_log_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "ventas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "webhook_e2_huerfanos_log_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "ventas_atribucion_normalizada"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "webhook_e2_huerfanos_log_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "vista_atribucion_web"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "webhook_e2_huerfanos_log_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "vista_atribucion_web_con_margen"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "webhook_e2_huerfanos_log_venta_item_id_fkey"
            columns: ["venta_item_id"]
            isOneToOne: false
            referencedRelation: "venta_items"
            referencedColumns: ["id"]
          },
        ]
      }
      weekly_snapshot: {
        Row: {
          aov: number | null
          clientes_nuevos: number | null
          clientes_recurrentes: number | null
          created_at: string | null
          cvr_web: number | null
          delta_aov_pct: number | null
          delta_cvr_pct: number | null
          delta_roas_pct: number | null
          delta_ventas_pct: number | null
          emails_enviados: number | null
          gasto_meta: number | null
          id: string
          impresiones_meta: number | null
          ingresos_email: number | null
          insights_generados: number | null
          mix_canal_web: Json | null
          open_rate_semana: number | null
          ordenes_total: number | null
          resumen_ai: string | null
          revenue_paid_atribuido: number | null
          roas_meta: number | null
          roas_meta_atribuido: number | null
          semana_fin: string
          semana_inicio: string
          sesiones: number | null
          top_ad_id: string | null
          top_canal: string | null
          top_producto_id: string | null
          ventas_offline: number | null
          ventas_shopify: number | null
          ventas_total: number | null
        }
        Insert: {
          aov?: number | null
          clientes_nuevos?: number | null
          clientes_recurrentes?: number | null
          created_at?: string | null
          cvr_web?: number | null
          delta_aov_pct?: number | null
          delta_cvr_pct?: number | null
          delta_roas_pct?: number | null
          delta_ventas_pct?: number | null
          emails_enviados?: number | null
          gasto_meta?: number | null
          id?: string
          impresiones_meta?: number | null
          ingresos_email?: number | null
          insights_generados?: number | null
          mix_canal_web?: Json | null
          open_rate_semana?: number | null
          ordenes_total?: number | null
          resumen_ai?: string | null
          revenue_paid_atribuido?: number | null
          roas_meta?: number | null
          roas_meta_atribuido?: number | null
          semana_fin: string
          semana_inicio: string
          sesiones?: number | null
          top_ad_id?: string | null
          top_canal?: string | null
          top_producto_id?: string | null
          ventas_offline?: number | null
          ventas_shopify?: number | null
          ventas_total?: number | null
        }
        Update: {
          aov?: number | null
          clientes_nuevos?: number | null
          clientes_recurrentes?: number | null
          created_at?: string | null
          cvr_web?: number | null
          delta_aov_pct?: number | null
          delta_cvr_pct?: number | null
          delta_roas_pct?: number | null
          delta_ventas_pct?: number | null
          emails_enviados?: number | null
          gasto_meta?: number | null
          id?: string
          impresiones_meta?: number | null
          ingresos_email?: number | null
          insights_generados?: number | null
          mix_canal_web?: Json | null
          open_rate_semana?: number | null
          ordenes_total?: number | null
          resumen_ai?: string | null
          revenue_paid_atribuido?: number | null
          roas_meta?: number | null
          roas_meta_atribuido?: number | null
          semana_fin?: string
          semana_inicio?: string
          sesiones?: number | null
          top_ad_id?: string | null
          top_canal?: string | null
          top_producto_id?: string | null
          ventas_offline?: number | null
          ventas_shopify?: number | null
          ventas_total?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "weekly_snapshot_top_producto_id_fkey"
            columns: ["top_producto_id"]
            isOneToOne: false
            referencedRelation: "productos"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      ads_pendientes_embedding: {
        Row: {
          ad_id: string | null
          ad_name: string | null
          adset_name: string | null
          asset_feed_bodies: string[] | null
          asset_feed_descriptions: string[] | null
          asset_feed_titles: string[] | null
          audiencia: string | null
          body_copy: string | null
          campaign_name: string | null
          cta: string | null
          headline: string | null
          image_hash: string | null
          image_url: string | null
          link_description: string | null
          objetivo: string | null
          optimization_goal: string | null
          targeting_summary: string | null
          video_id: string | null
          visual_description: string | null
        }
        Relationships: []
      }
      catalog_summary_for_vision: {
        Row: {
          catalog_text: string | null
        }
        Relationships: []
      }
      moments_atribucion_normalizada: {
        Row: {
          atribucion_inferida: boolean | null
          canal_consolidado: string | null
          moment_id: string | null
          occurred_at: string | null
          posicion: number | null
          referrer_url: string | null
          source_type: string | null
          utm_campaign_raw: string | null
          utm_medium_raw: string | null
          utm_source_raw: string | null
          venta_id: string | null
        }
        Insert: {
          atribucion_inferida?: never
          canal_consolidado?: never
          moment_id?: string | null
          occurred_at?: string | null
          posicion?: number | null
          referrer_url?: string | null
          source_type?: string | null
          utm_campaign_raw?: string | null
          utm_medium_raw?: string | null
          utm_source_raw?: string | null
          venta_id?: string | null
        }
        Update: {
          atribucion_inferida?: never
          canal_consolidado?: never
          moment_id?: string | null
          occurred_at?: string | null
          posicion?: number | null
          referrer_url?: string | null
          source_type?: string | null
          utm_campaign_raw?: string | null
          utm_medium_raw?: string | null
          utm_source_raw?: string | null
          venta_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "shopify_customer_moments_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "v_ventas_atribuidas"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "shopify_customer_moments_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "ventas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shopify_customer_moments_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "ventas_atribucion_normalizada"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "shopify_customer_moments_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "vista_atribucion_web"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "shopify_customer_moments_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "vista_atribucion_web_con_margen"
            referencedColumns: ["venta_id"]
          },
        ]
      }
      organic_visuals_pendientes: {
        Row: {
          asset_id: string | null
          asset_type: string | null
          fecha_publicacion: string | null
          image_url: string | null
          plataforma: string | null
          tipo: string | null
        }
        Relationships: []
      }
      posts_pendientes_embedding: {
        Row: {
          caption: string | null
          fecha_publicacion: string | null
          meta_post_id: string | null
          plataforma: string | null
          tipo: string | null
        }
        Relationships: []
      }
      product_embeddings_pendientes_fusion: {
        Row: {
          descripcion_visual_principal: string | null
          producto_id: string | null
          texto_actual: string | null
        }
        Relationships: [
          {
            foreignKeyName: "product_embeddings_producto_id_fkey"
            columns: ["producto_id"]
            isOneToOne: true
            referencedRelation: "productos"
            referencedColumns: ["id"]
          },
        ]
      }
      v_huerfanos_pendientes: {
        Row: {
          cantidad: number | null
          confianza_sugerida: string | null
          detected_at: string | null
          diagnostico_shopify: string | null
          dias_pendiente: number | null
          log_id: string | null
          match_sku_producto: string | null
          match_sku_variante: string | null
          match_sku_variante_id: string | null
          match_titulo_producto: string | null
          match_titulo_score: number | null
          match_titulo_variante: string | null
          match_titulo_variante_id: string | null
          notas: string | null
          numero_orden: number | null
          precio_unitario: number | null
          producto_titulo: string | null
          shopify_variant_id: string | null
          sku: string | null
          sku_es_ambiguo: boolean | null
          sku_total_candidatos: number | null
          valor_linea: number | null
          variante_titulo: string | null
          venta_item_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "webhook_e2_huerfanos_log_venta_item_id_fkey"
            columns: ["venta_item_id"]
            isOneToOne: false
            referencedRelation: "venta_items"
            referencedColumns: ["id"]
          },
        ]
      }
      v_loop_pending_close: {
        Row: {
          accion_evaluada: string | null
          accion_tomada: boolean | null
          dominio: string | null
          id: string | null
          metrica_clave: string | null
          periodo_fin: string | null
          score_confianza: number | null
          tipo: string | null
          titulo: string | null
          ultima_confirmacion: string | null
          valor_observado: number | null
        }
        Insert: {
          accion_evaluada?: string | null
          accion_tomada?: boolean | null
          dominio?: string | null
          id?: string | null
          metrica_clave?: string | null
          periodo_fin?: string | null
          score_confianza?: number | null
          tipo?: string | null
          titulo?: string | null
          ultima_confirmacion?: string | null
          valor_observado?: number | null
        }
        Update: {
          accion_evaluada?: string | null
          accion_tomada?: boolean | null
          dominio?: string | null
          id?: string | null
          metrica_clave?: string | null
          periodo_fin?: string | null
          score_confianza?: number | null
          tipo?: string | null
          titulo?: string | null
          ultima_confirmacion?: string | null
          valor_observado?: number | null
        }
        Relationships: []
      }
      v_loop_system_health: {
        Row: {
          alta_confianza: number | null
          closer_runs_60d: number | null
          cobertura_loop_pct: number | null
          con_accion_tomada: number | null
          dias_desde_closer: number | null
          dias_desde_weekly: number | null
          evaluados: number | null
          insights_vigentes: number | null
          ultimo_closer_ok: string | null
          ultimo_weekly_ok: string | null
          weekly_runs_60d: number | null
        }
        Relationships: []
      }
      v_meta_ads_roas_real: {
        Row: {
          adset_id: string | null
          adset_name: string | null
          campaign_id: string | null
          campaign_name: string | null
          clics_link: number | null
          compras_segun_meta: number | null
          cpa_real_cop: number | null
          gasto_cop: number | null
          impresiones: number | null
          primera_fecha: string | null
          revenue_real_cop: number | null
          revenue_segun_meta: number | null
          roas_real: number | null
          sesiones_atribuidas: number | null
          ultima_fecha: string | null
          ventas_no_atribuidas_por_meta: number | null
          ventas_reales: number | null
        }
        Relationships: []
      }
      v_paid_performance_diario: {
        Row: {
          ads_activos: number | null
          adset_id: string | null
          adset_name: string | null
          campaign_id: string | null
          campaign_name: string | null
          clics: number | null
          cobertura_cogs: string | null
          cogs_atribuido: number | null
          compras_meta_reportadas: number | null
          fecha: string | null
          gasto: number | null
          impresiones: number | null
          margen_atribuido: number | null
          pixel_value_bug: boolean | null
          revenue_atribuido: number | null
          roas_margen: number | null
          roas_revenue: number | null
          valor_compras_meta_reportado: number | null
          ventas_atribuidas: number | null
        }
        Relationships: []
      }
      v_ventas_atribuidas: {
        Row: {
          canal: string | null
          cliente_email: string | null
          cliente_ltv: number | null
          cliente_segmento: string | null
          customer_order_index: number | null
          days_to_conversion: number | null
          first_ad_id: string | null
          first_campaign: string | null
          first_medium: string | null
          first_source: string | null
          journey_ready: boolean | null
          last_campaign: string | null
          last_medium: string | null
          last_source: string | null
          moments_count: number | null
          numero_orden: string | null
          ordered_at: string | null
          shopify_order_id: string | null
          tipo_compra: string | null
          total: number | null
          total_pedidos: number | null
          venta_id: string | null
        }
        Relationships: []
      }
      ventas_atribucion_normalizada: {
        Row: {
          atribucion_inferida: boolean | null
          canal: string | null
          canal_consolidado: string | null
          cliente_id: string | null
          numero_orden: string | null
          ordered_at: string | null
          plataforma: string | null
          referrer_url: string | null
          shopify_order_id: string | null
          shopify_source_type: string | null
          tipo: string | null
          total: number | null
          utm_campaign_raw: string | null
          utm_medium_raw: string | null
          utm_source_raw: string | null
          venta_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "ventas_cliente_id_fkey"
            columns: ["cliente_id"]
            isOneToOne: false
            referencedRelation: "clientes"
            referencedColumns: ["id"]
          },
        ]
      }
      ventas_multi_touch_attribution: {
        Row: {
          atribucion_inferida: boolean | null
          canal_consolidado: string | null
          cliente_id: string | null
          ingresos_first_touch: number | null
          ingresos_last_touch: number | null
          ingresos_linear: number | null
          ingresos_u_shape: number | null
          moment_at: string | null
          moment_id: string | null
          numero_orden: string | null
          orden_total: number | null
          ordered_at: string | null
          peso_first_touch: number | null
          peso_last_touch: number | null
          peso_linear: number | null
          peso_u_shape: number | null
          posicion: number | null
          referrer_url: string | null
          shopify_order_id: string | null
          total_moments: number | null
          utm_campaign_raw: string | null
          utm_medium_raw: string | null
          utm_source_raw: string | null
          venta_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "shopify_customer_moments_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "v_ventas_atribuidas"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "shopify_customer_moments_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "ventas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shopify_customer_moments_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "ventas_atribucion_normalizada"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "shopify_customer_moments_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "vista_atribucion_web"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "shopify_customer_moments_venta_id_fkey"
            columns: ["venta_id"]
            isOneToOne: false
            referencedRelation: "vista_atribucion_web_con_margen"
            referencedColumns: ["venta_id"]
          },
          {
            foreignKeyName: "ventas_cliente_id_fkey"
            columns: ["cliente_id"]
            isOneToOne: false
            referencedRelation: "clientes"
            referencedColumns: ["id"]
          },
        ]
      }
      vista_atribucion_web: {
        Row: {
          adset_id: string | null
          adset_name: string | null
          campaign_id: string | null
          campaign_name: string | null
          canal_tipo: string | null
          clics_adset_ventana_30d: number | null
          days_to_conversion: number | null
          gasto_adset_ventana_30d: number | null
          impresiones_adset_ventana_30d: number | null
          metodo_match: string | null
          moments_count: number | null
          ordered_at: string | null
          revenue_venta: number | null
          source_type: string | null
          utm_campaign_slug: string | null
          utm_content_creative: string | null
          utm_medium: string | null
          utm_source: string | null
          utm_term_adset_id: string | null
          venta_id: string | null
        }
        Relationships: []
      }
      vista_atribucion_web_con_margen: {
        Row: {
          adset_id: string | null
          adset_name: string | null
          campaign_id: string | null
          campaign_name: string | null
          canal_tipo: string | null
          clics_adset_ventana_30d: number | null
          cobertura_cogs: string | null
          cogs_venta: number | null
          days_to_conversion: number | null
          gasto_adset_ventana_30d: number | null
          impresiones_adset_ventana_30d: number | null
          margen_pct: number | null
          margen_venta: number | null
          metodo_match: string | null
          moments_count: number | null
          ordered_at: string | null
          revenue_venta: number | null
          source_type: string | null
          utm_campaign_slug: string | null
          utm_content_creative: string | null
          utm_medium: string | null
          utm_source: string | null
          utm_term_adset_id: string | null
          venta_id: string | null
        }
        Relationships: []
      }
      visuals_pendientes: {
        Row: {
          asset_id: string | null
          asset_type: string | null
          image_hash: string | null
          image_url: string | null
          sample_ad_name: string | null
          video_id: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      analytics_close_insight_loop: {
        Args: { p_insight_id: string }
        Returns: Json
      }
      analytics_compute_weekly_snapshot: {
        Args: { p_fin: string; p_inicio: string }
        Returns: Json
      }
      analytics_compute_weekly_snapshot_v2: {
        Args: { p_fin: string; p_inicio: string }
        Returns: Json
      }
      analytics_compute_weekly_snapshot_v3: {
        Args: { p_fin: string; p_inicio: string }
        Returns: Json
      }
      analytics_decay_stale_insights: { Args: never; Returns: Json }
      analytics_detect_anomalies: {
        Args: { p_fin: string; p_inicio: string }
        Returns: Json
      }
      analytics_recompute_audience_segments: {
        Args: { p_fecha_corte?: string }
        Returns: Json
      }
      analytics_recompute_creative_learnings: {
        Args: { p_lookback_days?: number }
        Returns: Json
      }
      analytics_upsert_insight: { Args: { p_insight: Json }; Returns: Json }
      aplicar_reconciliacion_huerfano: {
        Args: {
          p_confianza?: string
          p_estrategia: string
          p_justificacion: string
          p_log_id: string
          p_variante_id: string
        }
        Returns: Json
      }
      backfill_inventario: { Args: { inventory_data: Json }; Returns: Json }
      backfill_orders: { Args: { orders_data: Json }; Returns: Json }
      backfill_products: { Args: { products_data: Json }; Returns: Json }
      backfill_single_order: { Args: { order_data: Json }; Returns: Json }
      buscar_brand_knowledge: {
        Args: {
          filtro_categoria?: string
          limite?: number
          query_embedding: string
        }
        Returns: {
          categoria: string
          contenido: string
          id: string
          similitud: number
          titulo: string
        }[]
      }
      buscar_creativos: {
        Args: {
          filtro_audiencia?: string
          filtro_objetivo?: string
          limite?: number
          query_embedding: string
        }
        Returns: {
          ad_id: string
          ad_name: string
          audiencia: string
          campaign_name: string
          cta: string
          objetivo: string
          similitud: number
          texto_fuente: string
        }[]
      }
      buscar_posts: {
        Args: {
          filtro_plataforma?: string
          filtro_tipo?: string
          limite?: number
          query_embedding: string
        }
        Returns: {
          meta_post_id: string
          plataforma: string
          similitud: number
          texto_fuente: string
          tipo: string
        }[]
      }
      buscar_productos: {
        Args: {
          filtro_coleccion?: string
          filtro_tipo?: string
          limite?: number
          query_embedding: string
        }
        Returns: {
          coleccion: string
          producto_id: string
          similitud: number
          temporada: string
          tipo: string
          titulo: string
        }[]
      }
      es_tarjeta_regalo: { Args: { p_producto_id: string }; Returns: boolean }
      extract_utm_param: {
        Args: { param_name: string; url: string }
        Returns: string
      }
      get_memoria_activa: {
        Args: {
          dominio_filtro?: string
          limite_insights?: number
          limite_learnings?: number
        }
        Returns: Json
      }
      get_orders_pending_journey: {
        Args: never
        Returns: {
          ordered_at: string
          shopify_order_id: string
        }[]
      }
      match_creatives_visuals_to_products: {
        Args: { payload: Json }
        Returns: {
          asset_id: string
          match_method: string
          match_score: number
          matched: boolean
          producto_id: string
        }[]
      }
      retry_huerfanos_pendientes: {
        Args: { p_grace_period_minutes?: number; p_max_retries?: number }
        Returns: Json
      }
      show_limit: { Args: never; Returns: number }
      show_trgm: { Args: { "": string }; Returns: string[] }
      sync_ubicaciones: { Args: { locations_data: Json }; Returns: Json }
      unaccent: { Args: { "": string }; Returns: string }
      update_ventas_utm_from_amplitude: {
        Args: { attribution_data: Json }
        Returns: Json
      }
      upsert_amplitude_daily: { Args: { metrics_data: Json }; Returns: Json }
      upsert_amplitude_top_content: {
        Args: { content_data: Json }
        Returns: Json
      }
      upsert_customer: { Args: { customer_data: Json }; Returns: Json }
      upsert_inventory_level: { Args: { level_data: Json }; Returns: Json }
      upsert_klaviyo_campaigns: {
        Args: { campaigns_data: Json }
        Returns: Json
      }
      upsert_klaviyo_profiles: { Args: { profiles_data: Json }; Returns: Json }
      upsert_meta_ads: { Args: { ads_data: Json }; Returns: Json }
      upsert_meta_organic: { Args: { posts_data: Json }; Returns: Json }
      upsert_shopify_journey: {
        Args: { journeys_data: Json }
        Returns: {
          errors: number
          journeys_upserted: number
          moments_inserted: number
          orders_not_found: number
          total_input: number
          ventas_utm_updated: number
        }[]
      }
    }
    Enums: {
      [_ in never]: never
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
  public: {
    Enums: {},
  },
} as const
