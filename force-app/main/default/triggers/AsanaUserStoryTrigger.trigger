trigger AsanaUserStoryTrigger on copado__User_Story__c (after update) {

    List<Asana_Field_Mapping__mdt> mappings = [
        SELECT Copado_Field_API_Name__c
        FROM Asana_Field_Mapping__mdt
        WHERE Is_Active__c = true
        AND (Direction__c = 'Outbound' OR Direction__c = 'Both')
    ];

    Set<String> watchedFields = new Set<String>();
    for (Asana_Field_Mapping__mdt m : mappings) {
        watchedFields.add(m.Copado_Field_API_Name__c);
    }

    for (copado__User_Story__c newUS : Trigger.new) {
        copado__User_Story__c oldUS = Trigger.oldMap.get(newUS.Id);
        String asanaTaskId = (String) newUS.get('Asana_Task_Id__c');
        if (String.isBlank(asanaTaskId)) continue;

        Boolean hasChanged = false;
        for (String fieldName : watchedFields) {
            if (newUS.get(fieldName) != oldUS.get(fieldName)) {
                hasChanged = true;
                break;
            }
        }

        if (hasChanged) {
            AsanaOutboundSync.updateAsanaTask(asanaTaskId, newUS.Id);
        }
    }
}