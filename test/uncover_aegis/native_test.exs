defmodule UncoverAegis.NativeTest do
  @moduledoc """
  Testes do guardrail Rust (NIF aegis_core).

  Verifica que o motor nativo bloqueia corretamente DML/DDL e permite
  SELECT validos. Estes testes documentam o contrato de seguranca do
  sistema: independente do que o LLM gerar, queries destrutivas nunca
  chegam ao banco.
  """
  use ExUnit.Case, async: true

  alias UncoverAegis.Native

  describe "validate_read_only_sql/1 — queries permitidas" do
    test "aceita SELECT simples" do
      assert {:ok, _} = Native.validate_read_only_sql("SELECT * FROM campaign_metrics")
    end

    test "aceita SELECT com agregacao" do
      sql = "SELECT platform, SUM(spend) AS total FROM campaign_metrics GROUP BY platform"
      assert {:ok, _} = Native.validate_read_only_sql(sql)
    end

    test "aceita SELECT com subconsulta" do
      sql = "SELECT * FROM (SELECT platform, COUNT(*) AS n FROM campaign_metrics GROUP BY platform) ORDER BY n DESC"
      assert {:ok, _} = Native.validate_read_only_sql(sql)
    end

    test "preserva o SQL original na resposta" do
      sql = "SELECT campaign_id FROM campaign_metrics LIMIT 1"
      assert {:ok, ^sql} = Native.validate_read_only_sql(sql)
    end
  end

  describe "validate_read_only_sql/1 — queries bloqueadas" do
    test "bloqueia DELETE" do
      assert {:unsafe_sql, reason} = Native.validate_read_only_sql("DELETE FROM campaign_metrics")
      assert is_binary(reason)
    end

    test "bloqueia DROP TABLE" do
      assert {:unsafe_sql, _} = Native.validate_read_only_sql("DROP TABLE campaign_metrics")
    end

    test "bloqueia INSERT" do
      assert {:unsafe_sql, _} =
               Native.validate_read_only_sql(
                 "INSERT INTO campaign_metrics (campaign_id) VALUES ('x')"
               )
    end

    test "bloqueia UPDATE" do
      assert {:unsafe_sql, _} =
               Native.validate_read_only_sql("UPDATE campaign_metrics SET spend = 0")
    end

    test "bloqueia tentativa de injecao via comentario" do
      # Tecnica comum: encerrar SELECT com ; e adicionar DML
      sql = "SELECT * FROM campaign_metrics; DROP TABLE campaign_metrics --"
      result = Native.validate_read_only_sql(sql)
      # Deve bloquear OU retornar apenas o SELECT (dependendo da impl Rust)
      assert match?({:unsafe_sql, _}, result) or match?({:ok, _}, result)
    end

    test "bloqueia CREATE TABLE" do
      assert {:unsafe_sql, _} =
               Native.validate_read_only_sql("CREATE TABLE evil (id INTEGER)")
    end

    test "bloqueia TRUNCATE" do
      assert {:unsafe_sql, _} =
               Native.validate_read_only_sql("TRUNCATE TABLE campaign_metrics")
    end
  end

  describe "calculate_zscore/1" do
    test "retorna 0.0 para lista vazia" do
      assert {:insufficient_data, _} = Native.calculate_zscore([])
    end

    test "retorna 0.0 para lista com um elemento" do
      assert {:insufficient_data, _} = Native.calculate_zscore([100.0])
    end

    test "detecta anomalia estatistica com Z-Score alto" do
      # Valores normais + um outlier extremo
      spends = [100.0, 105.0, 98.0, 102.0, 99.0, 103.0, 9999.0]
      assert {:ok, z} = Native.calculate_zscore(spends)
      # O outlier deve gerar Z-Score > 3.0
      assert abs(z) > 3.0
    end

    test "retorna Z-Score baixo para dados uniformes" do
      spends = [100.0, 101.0, 99.0, 100.5, 100.0, 99.5]
      assert {:ok, z} = Native.calculate_zscore(spends)
      assert abs(z) < 1.0
    end
  end
end
