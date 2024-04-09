--ALTER PROC PROC_LIMPEZA_DIR (@Percent_Espaco_Limite FLOAT, @Repr_Dir_Delete FLOAT ) AS
DECLARE @Html VARCHAR(MAX) = '<!DOCTYPE html>
<html>
<head>
	<meta charset="utf-8">
	<meta name="viewport" content="width=device-width, initial-scale=1">
	<style>
        table {
            width: 100%;
            border-collapse: collapse;
        }
        th, td {
            padding: 8px;
            text-align: left;
            border-bottom: 1px solid #ddd;
        }
        th {
            background-color: #f2f2f2;
        }
        #Div_Titulo {
        	background-color: #363636;
        	color: white;
        	font-family: roboto

        }
    </style>
</head>
<body>
	<center><div id="Div_Titulo"><h2> DETALHAMENTO DE DISCO </h2></div></center>
	<form>
		<table>
			<tr>
				<th><center>DISCO</center></th>
				<th><center>TOTAL</center></th>
				<th><center>EM USO</center></th>
				<th><center>DISPONIVEL</center></th>
				<th><center>% EM USO</center></th>
				<th><center>% DISPONIVEL</center></th>
			</tr>
			';

-- =================================================================================
--        # INICIANDO ETAPAS DE AVALIAÇÃO E TRATATIVA DE LIMPEZA NO DISCO
-- =================================================================================
	DECLARE @Dir NVARCHAR(40) = 'E:\'
	DECLARE @Cmd NVARCHAR(1000) = 'fsutil volume diskfree '+@Dir
	
	DROP TABLE IF EXISTS #INFO_DIR;
	CREATE TABLE #INFO_DIR (VLM VARCHAR(1000))
	
	INSERT INTO #INFO_DIR
	EXEC xp_cmdshell @Cmd;
	
	DELETE FROM #INFO_DIR
	WHERE VLM NOT LIKE '%Bytes%'
	
	
	DECLARE @Espaco_Disco FLOAT , @Espaco_Disponivel FLOAT, @Espaco_Uso FLOAT, @Percent_Espaco_Disponivel FLOAT, @Percent_Espaco_Em_Uso FLOAT;
	
	SELECT 
		  @Espaco_Disco = ESPACO_DISCO
		, @Espaco_Uso = (ESPACO_DISCO - ESPACO_DISPONIVEL)
		, @Espaco_Disponivel = ESPACO_DISPONIVEL
	FROM 
	(
		SELECT 
			    CONVERT(FLOAT,REPLACE(LEFT(VLM_PRE_FORMATADO,LEN(VLM_PRE_FORMATADO) -4),',','.')) VLM_FORMATADO
			  , CASE 
					WHEN RNK = 1 THEN 'ESPACO_DISPONIVEL'
					WHEN RNK = 2 THEN 'ESPACO_DISCO'
				END COLUNAS
			
		FROM(
			SELECT TOP 2
				  *
				, RIGHT(VLM,(LEN(VLM)-CHARINDEX('(',VLM, 1))) VLM_PRE_FORMATADO
				, ROW_NUMBER() OVER(ORDER BY (SELECT NULL)) AS RNK
		 	FROM #INFO_DIR
			WHERE VLM IS NOT NULL
		 ) A
	) B
	PIVOT(MAX(VLM_FORMATADO) FOR COLUNAS IN ([ESPACO_DISPONIVEL],[ESPACO_DISCO])) PV;
	
	-- # OBTENDO O %PERCENT. DE ESPAÇO DISPONIVEL E EM USO
	SET @Percent_Espaco_Disponivel = ROUND( (@Espaco_Disponivel / @Espaco_Disco) ,2);
	SET @Percent_Espaco_Em_Uso = ROUND( (@Espaco_Uso / @Espaco_Disco) ,2);

	SELECT @HTML = @HTML+'<tr>
				<td><center>'+CONVERT(VARCHAR(100),@Dir)+'</center></td>
				<td><center>'+CONVERT(VARCHAR(100),@Espaco_Disco)+' GB</center></td>
				<td><center>'+CONVERT(VARCHAR(100),@Espaco_Uso)+' GB</center></td>
				<td><center>'+CONVERT(VARCHAR(100),@Espaco_Disponivel)+' GB</center></td>	
				<td><center>'+CONVERT(VARCHAR(100),@Percent_Espaco_Em_Uso * 100)+'%</center></td>
				<td><center>'+CONVERT(VARCHAR(100),@Percent_Espaco_Disponivel * 100)+'%</center></td>
			</tr>
		</table>
	</form>
</body>
</html>
'
	-- ==================================
	--   # ENVIANDO REPORT - INFO DISCO
	-- ==================================

	BEGIN TRY 
		EXEC msdb.dbo.sp_send_dbmail 
	
		@profile_name = 'SQL_TESTE', 
		@recipients = '', 
		@body_format = 'HTML',
		@body = @Html,
		@subject = '[ REPORT ] - MONITORAMENTO DE DISCO ';
	END TRY
	
	BEGIN CATCH END CATCH
	

	-- =====================================
	-- #   OBTENDO INFO. DO DIRETORIO
	-- =====================================
	
	DROP TABLE IF EXISTS #RESULTADO_DIR;
	CREATE TABLE #RESULTADO_DIR ([OUTPUT] VARCHAR(MAX));
	
	DROP TABLE IF EXISTS #LIST_DIR;
	CREATE TABLE #LIST_DIR (DT_CRIACAO DATETIME, ARQUIVO VARCHAR(200), TAMANHO_ARQUIVO FLOAT);
	
	
	DECLARE @Pasta VARCHAR(100) = @Dir+'ARQUIVOS\'
	DECLARE @CmdDir VARCHAR(1000) = 'dir '+@Pasta;
	
	INSERT INTO #RESULTADO_DIR
	EXEC xp_cmdshell @CmdDir
	
	INSERT INTO #LIST_DIR
	SELECT 
		  CONVERT(DATETIME,DT_CRIACAO, 121) AS DT_CRIACAO 
		, SUBSTRING(OBTEM_INFO,CHARINDEX(' ',OBTEM_INFO,1),1000) AS ARQUIVO 
		, CONVERT(FLOAT,REPLACE(LEFT(OBTEM_INFO,CHARINDEX(' ',OBTEM_INFO,1)-1),'.','')) AS TAMANHO_ARQUIVO
		
	FROM
	(
		SELECT *
			, CONCAT(SUBSTRING([OUTPUT],7,4),'-', SUBSTRING([OUTPUT],4,2),'-',LEFT([OUTPUT],2),SUBSTRING([OUTPUT],12,6)+':00.000') AS DT_CRIACAO
			, TRIM(SUBSTRING([OUTPUT],18,1000)) OBTEM_INFO
			,
			  CASE 
				  WHEN [OUTPUT] LIKE '%.csv' THEN 1
				  WHEN [OUTPUT] LIKE '%.txt' THEN 1
				  WHEN [OUTPUT] LIKE '%.xlsx' THEN 1
			  END ARQUIVO_REGRA
		FROM #RESULTADO_DIR
	) A
	WHERE ARQUIVO_REGRA = 1
	
	
	-- =====================================
	-- # REALIZANDO LIMPEZA NO DIRETORIO
	-- =====================================
	IF @Percent_Espaco_Disponivel <= 1
	BEGIN
		DECLARE @OFFSET INT = 0, @LOTE INT = 1, @X INT, @Cmd_Del VARCHAR(1000), @FileName VARCHAR(1000), @FileNameConcat VARCHAR(MAX)= '';
		
		WHILE 1=1
		
		BEGIN
			SELECT @Cmd_Del = 'del '+@Pasta+TRIM(ARQUIVO) , @FileName = @Pasta+TRIM(ARQUIVO) 
			FROM(
				SELECT 
					  *
					, SUM(REPR) OVER(ORDER BY REPR DESC) REPR_ACUMULADA 
				FROM 
				(
					SELECT *, ROUND(TAMANHO_ARQUIVO / (SUM(TAMANHO_ARQUIVO) OVER(PARTITION BY 1)),2) REPR
					FROM #LIST_DIR
				) B
			) C
			WHERE REPR_ACUMULADA <= 0.40
			ORDER BY REPR_ACUMULADA 
			
			OFFSET @OFFSET ROWS
			FETCH NEXT @LOTE ROWS ONLY
		
			IF @@ROWCOUNT = 0
				BREAK;
			SET @OFFSET +=1
			
			BEGIN TRY
				EXEC xp_cmdshell @Cmd_Del;
				INSERT INTO TB_LOG (ARQUIVO, DATA_DELETE) VALUES (@FileName, CURRENT_TIMESTAMP)
			END TRY
			BEGIN CATCH END CATCH
			
			SET @FileNameConcat = @FileNameConcat + ' '''+@FileName + ''' ,'


		

	SET @FileNameConcat = LEFT(@FileNameConcat, IIF(LEN(@FileNameConcat) > 0,(LEN(@FileNameConcat)-1),0));

	-- ==============================================================================
	--        # CONSULTANDO NA TABELA DE LOG OS ARQUIVOS DELETADOS NO PROCESSO
	-- ==============================================================================
	DROP TABLE IF EXISTS #RESULT_LOG;
	CREATE TABLE #RESULT_LOG (ARQUIVO VARCHAR(1000), DATA_DELETE DATETIME);

	DECLARE @Query_Log VARCHAR(1000) = 'SELECT ARQUIVO, DATA_DELETE FROM TB_LOG WITH(NOLOCK) WHERE ARQUIVO IN ('
	
	SET @Query_Log = @Query_Log+@FileNameConcat+') AND CAST(DATA_DELETE AS DATE) = CAST(CURRENT_TIMESTAMP AS DATE)';
	
	INSERT INTO #RESULT_LOG
	EXEC (@Query_Log)
	
	-- ==============================================================================
	--        # FORMATANDO HTML E ENVIANDO REPORT APOS DELETE
	-- ==============================================================================
	
	DECLARE @Html_Del VARCHAR(MAX) = '<!DOCTYPE html>
			<html>
			<head>
				<meta charset="utf-8">
				<meta name="viewport" content="width=device-width, initial-scale=1">
				<style>
			        table {
			            width: 100%;
			            border-collapse: collapse;
			        }
			        th, td {
			            padding: 8px;
			            text-align: left;
			            border-bottom: 1px solid #ddd;
			        }
			        th {
			            background-color: #f2f2f2;
			        }
			        #Div_Titulo {
			        	background-color: #363636;
			        	color: white;
			        	font-family: roboto
			
			        }
			    </style>
			</head>
			<body>
				<center><div id="Div_Titulo"><h2> DETALHAMENTO DE LIMPEZA NO DIRETÓRIO </h2></div></center>
				<form>
					<table>
						<tr>
							<th><center>DIRETORIO</center></th>
							<th><center>ARQUIVO</center></th>
							<th><center>DATA DELETE</center></th>
						</tr>
						';
	DECLARE @OFFSET_2 INT = 0, @LOTE_2 INT = 1;
	WHILE 1=1 
	BEGIN
		SELECT @Html_Del  = @Html_Del +'<tr>
					<td><center>'+@Pasta+'</center></td>
					<td><center>'+ARQUIVO+'</center></td>
					<td><center>'+CONVERT(VARCHAR(100),DATA_DELETE)+'</center></td>
					</tr>
				</table>
			</form>
		</body>
		</html>
		'
	FROM #RESULT_LOG
	ORDER BY DATA_DELETE

	OFFSET @OFFSET_2 ROWS
	FETCH NEXT @LOTE_2 ROWS ONLY

	IF @@ROWCOUNT = 0 
		BREAK;
	
	SET @OFFSET_2 += 1;

	END
	
	-- ==================================
	--   # ENVIANDO REPORT - INFO DISCO
	-- ==================================
	DECLARE @TITULO VARCHAR(1000) =  '[ REPORT ] - LIMPEZA DE DIRETORIO '+@Pasta
	BEGIN TRY 
		EXEC msdb.dbo.sp_send_dbmail 
	
		@profile_name = 'SQL_TESTE', 
		@recipients = 'gabriellouhan123@gmail.com', 
		@body_format = 'HTML',
		@body = @Html_Del,
		@subject = @TITULO;
	END TRY
	
	BEGIN CATCH END CATCH
	END
END