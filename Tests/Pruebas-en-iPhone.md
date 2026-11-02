# Validación antes del uso diario

Esta lista no está aprobada: requiere ejecutar la app compilada en el iPhone.
Usar un calendario de prueba como calendario por omisión y eventos ficticios.
No modificar citas reales para comprobar el funcionamiento.

## Voz y conversación

| Prueba | Resultado necesario |
| --- | --- |
| Abrir el asistente por primera vez | Explicar permisos del sistema; el diálogo de permisos no cancela accidentalmente la apertura. |
| Denegar micrófono o reconocimiento | Mensaje comprensible; teclado disponible y agenda consultable; ningún cambio. |
| «Añade ensayo mañana a las diecisiete durante cuarenta minutos» | Una sola cita, fecha y duración correctas; respuesta breve y micrófono cerrado. |
| Pausa natural antes de decir la hora | No cortar la frase mientras continúa la voz; si falta la hora, preguntar sin guardar. |
| Ventilador de fondo y voz suave | No confundir ruido continuo con una petición ni recortar palabras. Medir y ajustar el umbral acústico. |
| «Mañana… perdón, el jueves a las dieciocho» | Aplicar la corrección, o pedir aclaración si queda ambigua. |
| «A las seis» sin contexto | Aclarar mañana/tarde antes de modificar. |
| Resultado final tardío o repetido | Como máximo una operación; ningún envío parcial. |
| Audio cortado, llamada o desconexión de auriculares | Detener la captura, conservar texto recuperable para revisar; no enviar una frase truncada. |
| Cerrar, bloquear o cambiar de app durante escucha e interpretación | Micrófono apagado y cero guardados posteriores a la cancelación recibida antes del guardado. |
| Cerrar mientras responde | Silencio; no reabrir el micrófono al terminar una respuesta atrasada. |
| «Cancela.» y «Olvídalo.» | Cancelar la aclaración, sin eliminar citas. |
| «Cancela la cita Ensayo de mañana» | Identificar una única cita y eliminar solo esa cita. |
| Pregunta pendiente seguida de una petición nueva | No ejecutar ni arrastrar datos de la petición abandonada. |
| Pregunta sobre una cita única, seguida de «muévela una hora» | Mover la cita de esa consulta, no una cita anterior. |
| Lista de varias citas, seguida de «la segunda» | Resolver únicamente la segunda opción que realmente se mostró. |
| Reconocimiento local no disponible / modo avión | Explicar la disponibilidad real; no activar una API remota de pago. |

## Calendario, cambios y deshacer

| Prueba | Resultado necesario |
| --- | --- |
| Crear en un horario ocupado | Informar del conflicto antes de guardar; aceptar un solape solo tras petición explícita. |
| Buscar un hueco y reservar una opción | Mantener la referencia al intervalo; volver a comprobar ocupación antes de guardar. |
| Mover y renombrar sin pedir cambiar notas/avisos | Preservar los campos no solicitados. |
| Mover un evento de todo el día a través de un cambio de hora | Mantener días completos del calendario, sin añadir ni perder una hora visual. |
| Consultar un evento de todo el día marcado como libre | Mostrarlo sin bloquear los huecos. |
| Consultar un evento de todo el día ocupado/tentativo | No ofrecer ese día como libre. |
| Editar una cita recurrente o con invitados | Ofrecer la ficha nativa; no alterar una serie o enviar invitaciones implícitamente. |
| Deshacer una eliminación | Restaurar título, fechas, calendario, notas, avisos, ubicación, URL y zona horaria admitidos. |
| Cambiar la cita fuera de Agenda y pedir deshacer | Detectar el cambio externo y evitar sobrescribirlo. |
| Revocar permiso de calendario | Mostrar la falta de acceso, nunca un día aparentemente vacío. |

## Interfaz y widget

| Prueba | Resultado necesario |
| --- | --- |
| Día con solapes, citas de cinco minutos y citas nocturnas | Todas las citas alcanzables; duraciones proporcionales; sin ocultarlas por quedar fuera de la franja principal. |
| Texto grande, VoiceOver, modo claro y oscuro | Leer títulos, horas y controles; distinguir ocupado/libre sin depender solo del color. |
| Widget recién añadido | Acceso al calendario comprobado en el dispositivo; abrir app si falta permiso. |
| Editar desde Agenda o desde Calendario | App actualiza; widget muestra cuándo se actualizó y no asegura inmediatez que iOS no garantiza. |
| Widget sin datos recientes o con error | No mostrar datos antiguos como una confirmación actual de disponibilidad. |
| Medianoche y cambio de zona horaria | Hoy y mañana corresponden al día local correcto. |

Registrar dispositivo, versión de iOS, idioma, permisos, fecha de prueba y resultado.
Una compilación correcta y las pruebas del núcleo no sustituyen estas comprobaciones.
