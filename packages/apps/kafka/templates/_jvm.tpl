{{- /*
  JAVA_TOOL_OPTIONS for a Strimzi-managed container, from its resource limits.
  The JDK 17 in the Strimzi images cannot see the container limits on kernels
  built without CONFIG_MEMCG_V1 (JDK-8347811) and sizes itself from the host:
  Strimzi's heap probe then hands every broker up to a 5Gi heap. Every java in
  the container reads this variable, the probe included, so Strimzi's own
  heap rules work again. jvmOptions -XX would not do: Strimzi moves those into
  KAFKA_JVM_PERFORMANCE_OPTS, and kafka-run-class.sh drops its G1 tuning when
  that variable is set. ActiveProcessorCount only when the chart sets a CPU
  limit: a default a LimitRange adds at admission is not visible here, and
  Strimzi template env takes no resourceFieldRef, so such a JVM still counts
  the host CPUs.
*/ -}}
{{- define "kafka.javaToolOptions" -}}
{{- $opts := list (printf "-XX:MaxRAM=%d" (include "cozy-lib.resources.toFloat" .memory | float64 | int64)) -}}
{{- with .cpu -}}
{{- $opts = append $opts (printf "-XX:ActiveProcessorCount=%d" (include "cozy-lib.resources.toFloat" . | float64 | ceil | int64)) -}}
{{- end -}}
{{- join " " $opts -}}
{{- end -}}
