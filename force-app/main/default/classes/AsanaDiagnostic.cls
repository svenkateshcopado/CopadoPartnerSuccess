public class AsanaDiagnostic {

    @InvocableMethod(label='Run Asana Diagnostic' description='Runs full diagnostic check on the Asana-Copado integration')
    public static void runFromFlow(List<String> inputs) {
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
        // STEP 1: Custom Setting check
        Asana_Integration_Settings__c settings = Asana_Integration_Settings__c.getOrgDefaults();
        if (settings == null) {
            System.debug('### DIAG [FAIL] Custom Setting record does not exist. Go to Setup > Custom Settings > Asana Integration Settings > Manage > New.');
            return;
        }

        // MEDIUM-04 FIX: Asana_PAT__c is never read, checked, or logged.
        // Named Credential 'AsanaCopado' handles authentication transparently.
        // The old 'patOk' guard that blocked diagnostics when PAT was absent is removed.
        Boolean gidOk = String.isNotBlank(settings.Asana_Project_GID__c);
        Boolean tagF  = String.isNotBlank(settings.Filter_By_Tag__c);
        Boolean cfF   = String.isNotBlank(settings.Filter_Custom_Field_Name__c)
                        && String.isNotBlank(settings.Filter_Custom_Field_Value__c);

        System.debug('### DIAG [Project GID configured] : ' + gidOk);
        System.debug('### DIAG [Project GID value]      : ' + (gidOk ? settings.Asana_Project_GID__c : 'EMPTY - SYNC WILL NOT RUN'));
        System.debug('### DIAG [Tag filter active]      : ' + tagF + (tagF ? ' | value = ' + settings.Filter_By_Tag__c : ' | all tasks allowed'));
        System.debug('### DIAG [Custom field filter]    : ' + cfF + (cfF ? ' | ' + settings.Filter_Custom_Field_Name__c + ' = ' + settings.Filter_Custom_Field_Value__c : ' | no custom field filter'));
        System.debug('### DIAG [Auth]                   : Named Credential AsanaCopado (PAT secured - not exposed in diagnostics)');

        if (!gidOk) {
            System.debug('### DIAG [FAIL] Cannot proceed. Project GID missing in Custom Setting.');
            return;
        }

        // STEP 2: Field mappings
        List<Asana_Field_Mapping__mdt> fms = [
            SELECT MasterLabel, Asana_Field_API_Name__c, Copado_Field_API_Name__c, Direction__c
            FROM Asana_Field_Mapping__mdt
            WHERE Is_Active__c = true AND (Direction__c = 'Inbound' OR Direction__c = 'Both')
        ];
        System.debug('### DIAG [Inbound field mappings active] : ' + fms.size());
        for (Asana_Field_Mapping__mdt m : fms) {
            System.debug('### DIAG   >> ' + m.MasterLabel + ' | ' + m.Asana_Field_API_Name__c + ' --> ' + m.Copado_Field_API_Name__c);
        }

        // STEP 3: Record type mappings
        List<Asana_Record_Type_Mapping__mdt> rms = [
            SELECT MasterLabel, Asana_Task_Value__c, Copado_Record_Type_Developer_Name__c, Is_Default__c
            FROM Asana_Record_Type_Mapping__mdt
            WHERE Is_Active__c = true
        ];
        System.debug('### DIAG [Record type mappings active]  : ' + rms.size());
        for (Asana_Record_Type_Mapping__mdt r : rms) {
            System.debug('### DIAG   >> ' + r.MasterLabel + ' | ' + r.Asana_Task_Value__c + ' --> ' + r.Copado_Record_Type_Developer_Name__c + ' | default=' + r.Is_Default__c);
        }

        // STEP 4: Copado User Story Record Types
        List<RecordType> rts = [SELECT Id, DeveloperName FROM RecordType WHERE SObjectType = 'copado__User_Story__c'];
        System.debug('### DIAG [Copado User Story RTs]        : ' + rts.size());
        for (RecordType rt : rts) {
            System.debug('### DIAG   RT >> ' + rt.DeveloperName + ' | ' + rt.Id);
        }

        // STEP 5: Live API connectivity test
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:AsanaCopado/api/1.0/projects/' + settings.Asana_Project_GID__c + '/tasks?opt_fields=gid,name&limit=1');
        req.setMethod('GET');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(10000);

        try {
            HttpResponse res = new Http().send(req);
            System.debug('### DIAG [API connectivity]           : HTTP ' + res.getStatusCode());
            if (res.getStatusCode() == 200) {
                System.debug('### DIAG [PASS] Named Credential auth successful. API reachable.');
            } else {
                System.debug('### DIAG [WARN] Unexpected status. Body: ' + res.getBody());
            }
        } catch (Exception e) {
            System.debug('### DIAG [FAIL] API call threw exception: ' + e.getMessage());
        }
    }
}