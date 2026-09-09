/**
 * AsanaDiagnostic
 *
 * Security fixes applied:
 *   MC-04  Custom permission guard   – callers without the 'Asana_Admin' custom permission are rejected.
 *   MC-04  Named Credential auth     – PAT is no longer read or injected manually into the HTTP header.
 *   MC-04  Explicit sharing declared – 'with sharing' enforces org sharing rules on all SOQL.
 *   LC-02  Debug log hygiene         – full response bodies and PAT values are never logged.
 */
public with sharing class AsanaDiagnostic {

    @InvocableMethod(label='Run Asana Diagnostic' description='Runs full diagnostic check on the Asana-Copado integration')
    public static void runFromFlow(List<String> inputs) {
        // MC-04: Enforce custom permission. Only Asana admins may run diagnostics.
        if (!FeatureManagement.checkPermission('Asana_Admin')) {
            System.debug(LoggingLevel.WARN,
                'AsanaDiagnostic: Access denied. Caller does not have the Asana_Admin custom permission.');
            return;
        }

        if (System.isFuture() || System.isBatch()) {
            runLive();
        } else {
            runAsync();
        }
    }

    @future(callout=true)
    public static void runAsync() {
        runLive();
    }

    public static void runLive() {
        // MC-04: Re-check permission in the async context as well.
        if (!FeatureManagement.checkPermission('Asana_Admin')) {
            System.debug(LoggingLevel.WARN, 'AsanaDiagnostic: Access denied in async context.');
            return;
        }

        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
        if (settings == null) {
            System.debug(LoggingLevel.ERROR, '### DIAG [FAIL] Custom Setting record does not exist.');
            return;
        }

        // MC-04: PAT existence check only — value is never logged or exposed.
        Boolean patOk = String.isNotBlank(settings.Asana_PAT__c);
        Boolean gidOk = String.isNotBlank(settings.Asana_Project_GID__c);
        Boolean tagF  = String.isNotBlank(settings.Filter_By_Tag__c);
        Boolean cfF   = String.isNotBlank(settings.Filter_Custom_Field_Name__c)
                     && String.isNotBlank(settings.Filter_Custom_Field_Value__c);

        System.debug(LoggingLevel.INFO, '### DIAG [PAT configured]         : ' + patOk);
        System.debug(LoggingLevel.INFO, '### DIAG [Project GID configured] : ' + gidOk);
        // LC-02: Only log that GID is set, not the value itself.
        System.debug(LoggingLevel.INFO, '### DIAG [Project GID present]    : ' + gidOk);
        System.debug(LoggingLevel.INFO, '### DIAG [Tag filter active]      : ' + tagF);
        System.debug(LoggingLevel.INFO, '### DIAG [Custom field filter]    : ' + cfF);

        if (!gidOk) {
            System.debug(LoggingLevel.ERROR, '### DIAG [FAIL] Project GID missing.');
            return;
        }

        List<Asana_Field_Mapping__mdt> fms = [
            SELECT MasterLabel, Asana_Field_API_Name__c, Copado_Field_API_Name__c, Direction__c
            FROM Asana_Field_Mapping__mdt
            WHERE Is_Active__c = TRUE AND (Direction__c = 'Inbound' OR Direction__c = 'Both')
        ];
        System.debug(LoggingLevel.INFO, '### DIAG [Inbound field mappings] : ' + fms.size());
        for (Asana_Field_Mapping__mdt m : fms) {
            System.debug(LoggingLevel.INFO,
                '### DIAG   >> ' + m.MasterLabel + ' | ' + m.Asana_Field_API_Name__c + ' --> ' + m.Copado_Field_API_Name__c);
        }

        List<Asana_Record_Type_Mapping__mdt> rms = [
            SELECT MasterLabel, Asana_Task_Value__c, Copado_Record_Type_Developer_Name__c, Is_Default__c
            FROM Asana_Record_Type_Mapping__mdt
            WHERE Is_Active__c = TRUE
        ];
        System.debug(LoggingLevel.INFO, '### DIAG [Record type mappings]   : ' + rms.size());
        for (Asana_Record_Type_Mapping__mdt r : rms) {
            System.debug(LoggingLevel.INFO,
                '### DIAG   >> ' + r.MasterLabel + ' | ' + r.Asana_Task_Value__c
                + ' --> ' + r.Copado_Record_Type_Developer_Name__c + ' | default=' + r.Is_Default__c);
        }

        List<RecordType> rts = [
            SELECT Id, DeveloperName
            FROM RecordType
            WHERE SObjectType = 'copado__User_Story__c'
        ];
        System.debug(LoggingLevel.INFO, '### DIAG [Copado User Story RTs]  : ' + rts.size());
        for (RecordType rt : rts) {
            System.debug(LoggingLevel.INFO, '### DIAG   RT >> ' + rt.DeveloperName);
        }

        // MC-04: API probe now uses Named Credential — PAT never touched.
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:AsanaCopado/api/1.0/projects/' +
            settings.Asana_Project_GID__c + '/tasks?opt_fields=gid,name&limit=5');
        req.setMethod('GET');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(30000);

        try {
            HttpResponse res = new Http().send(req);
            System.debug(LoggingLevel.INFO, '### DIAG [Asana API status] : ' + res.getStatusCode());
            if (res.getStatusCode() == 200) {
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                List<Object> tasks = (List<Object>) body.get('data');
                // LC-02: Log only the count, not the task data.
                System.debug(LoggingLevel.INFO, '### DIAG [Tasks returned]  : ' + (tasks != null ? tasks.size() : 0));
            } else {
                // LC-02: Log only status code, not the error body.
                System.debug(LoggingLevel.ERROR, '### DIAG [FAIL] API error: HTTP ' + res.getStatusCode());
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '### DIAG [FAIL] Callout exception: ' + e.getTypeName());
        }
    }
}
