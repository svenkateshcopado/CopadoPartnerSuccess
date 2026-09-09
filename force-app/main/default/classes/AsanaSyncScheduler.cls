public class AsanaSyncScheduler implements Schedulable {

    public void execute(SchedulableContext sc) {
        Map<String, Object> params = new Map<String, Object>();
        Flow.Interview interview = Flow.Interview.createInterview('Asana_To_Copado_Sync', params);
        interview.start();
    }
}