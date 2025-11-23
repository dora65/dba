WITH PermisosDirectos AS (
    SELECT 
        dp.principal_id,
        STUFF((
            SELECT ', ' + 
                dpm.permission_name +
                CASE dpm.state_desc
                    WHEN 'DENY' THEN ' (DENY)'
                    WHEN 'GRANT_WITH_GRANT_OPTION' THEN ' (WGO)'
                    ELSE ''
                END +
                CASE 
                    WHEN dpm.class_desc = 'OBJECT_OR_COLUMN' THEN ' ON ' + ISNULL(OBJECT_SCHEMA_NAME(dpm.major_id) + '.' + OBJECT_NAME(dpm.major_id), 'obj')
                    WHEN dpm.class_desc = 'SCHEMA' THEN ' ON SCHEMA::' + ISNULL(SCHEMA_NAME(dpm.major_id), 'sch')
                    WHEN dpm.class_desc = 'DATABASE' THEN ' ON DATABASE'
                    ELSE ''
                END
            FROM sys.database_permissions dpm
            WHERE dpm.grantee_principal_id = dp.principal_id
            ORDER BY dpm.permission_name
            FOR XML PATH(''), TYPE
        ).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS permisos_directos,
        MAX(CASE 
            WHEN dpm.permission_name IN ('CONTROL','ALTER ANY USER','ALTER ANY ROLE','IMPERSONATE','TAKE OWNERSHIP','CREATE DATABASE','DROP DATABASE','ALTER ANY DATABASE','ALTER ANY SCHEMA') THEN 1
            ELSE 0
        END) AS tiene_permisos_criticos_directos
    FROM sys.database_principals dp
    LEFT JOIN sys.database_permissions dpm ON dp.principal_id = dpm.grantee_principal_id
    GROUP BY dp.principal_id
),
RolesUsuario AS (
    SELECT 
        drm.member_principal_id,
        STUFF((
            SELECT ', ' + r.name
            FROM sys.database_role_members drm2
            JOIN sys.database_principals r ON drm2.role_principal_id = r.principal_id
            WHERE drm2.member_principal_id = drm.member_principal_id
            ORDER BY 
                CASE r.name
                    WHEN 'db_owner' THEN 1
                    WHEN 'db_securityadmin' THEN 2
                    WHEN 'db_accessadmin' THEN 3
                    WHEN 'db_ddladmin' THEN 4
                    WHEN 'loginmanager' THEN 5
                    WHEN 'dbmanager' THEN 6
                    WHEN 'db_backupoperator' THEN 7
                    WHEN 'db_datawriter' THEN 8
                    WHEN 'db_datareader' THEN 9
                    ELSE 10
                END,
                r.name
            FOR XML PATH(''), TYPE
        ).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS roles,
        MAX(CASE 
            WHEN r.name IN ('db_owner','db_securityadmin','db_accessadmin','db_ddladmin','loginmanager','dbmanager') THEN 1
            ELSE 0
        END) AS tiene_roles_criticos
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
    GROUP BY drm.member_principal_id
)
SELECT 
    ROW_NUMBER() OVER (ORDER BY 
        CASE 
            WHEN ru.tiene_roles_criticos = 1 OR pd.tiene_permisos_criticos_directos = 1 THEN 1
            WHEN ru.roles LIKE '%db_datawriter%' OR ru.roles LIKE '%db_datareader%' THEN 2
            WHEN dp.type = 'S' THEN 3
            ELSE 4
        END,
        dp.name
    ) AS [#],
    dp.name AS Usuario,
    dp.type_desc + ' [' + 
    CASE dp.authentication_type
        WHEN 1 THEN 'SQL-LOGIN'
        WHEN 2 THEN 'SQL-CONTAINED'
        WHEN 3 THEN 'WINDOWS'
        WHEN 4 THEN 'AZURE-AD'
        ELSE 'N/A'
    END + ']' AS TipoUsuario,
    ISNULL(ru.roles, 'Sin roles') AS Roles,
    ISNULL(pd.permisos_directos, 'Sin permisos directos') AS PermisosDirectos,
    FORMAT(dp.create_date, 'yyyy-MM-dd') + ' (' +
    CAST(DATEDIFF(DAY, dp.create_date, GETDATE()) / 365 AS VARCHAR) + ' años ' +
    CAST((DATEDIFF(DAY, dp.create_date, GETDATE()) % 365) / 30 AS VARCHAR) + ' meses ' +
    CAST(DATEDIFF(DAY, dp.create_date, GETDATE()) % 30 AS VARCHAR) + ' días)' AS Antiguedad,
    CASE
        WHEN ru.tiene_roles_criticos = 1 THEN 'ALTO - Roles admin'
        WHEN pd.tiene_permisos_criticos_directos = 1 THEN 'ALTO - Permisos críticos'
        WHEN ru.roles LIKE '%db_datawriter%' OR ru.roles LIKE '%db_datareader%' THEN 'MEDIO - Lectura/escritura'
        WHEN dp.authentication_type = 2 THEN 'MEDIO - SQL contenido'
        WHEN dp.authentication_type = 1 THEN 'MEDIO - SQL login'
        ELSE 'BAJO'
    END AS NivelRiesgo
FROM sys.database_principals dp
LEFT JOIN PermisosDirectos pd ON dp.principal_id = pd.principal_id
LEFT JOIN RolesUsuario ru ON dp.principal_id = ru.member_principal_id
WHERE dp.type IN ('S','U','G','E','X','C','K')
  AND dp.name NOT LIKE '##MS_%'
  AND dp.name NOT IN ('dbo','guest','INFORMATION_SCHEMA','sys','public')
  AND dp.is_fixed_role = 0
  AND dp.principal_id > 4
ORDER BY [#];