# Agenda · código 0.2.0

Versión de desarrollo para iPhone. La voz está integrada en el código; todavía no es una aplicación compilada, instalada o validada para uso diario.

## Uso previsto

Una pantalla con hoy y mañana, horas y bloques proporcionales. Los colores vienen de tus calendarios. Un botón de micrófono abre el asistente y comienza a escuchar; el teclado queda disponible para corregir una frase, sin abrirse automáticamente.

El asistente responde en voz alta a las peticiones habladas. Si necesita un dato, hace una pregunta breve y vuelve a escuchar. Al terminar una operación, cierra el micrófono. Cerrar el asistente, bloquear el iPhone o salir de la app cancela la escucha y las peticiones que aún no se han guardado.

El encabezado del día da acceso a citas nocturnas, bloques pequeños y solapes. Con tamaños de letra de accesibilidad usa una lista legible.

El widget grande muestra hoy y mañana en la pantalla de Inicio, con la hora de última lectura. iOS controla cuándo lo actualiza: no es una capa permanente sobre otras apps ni una vista grande en la pantalla de bloqueo. Si la información queda antigua o cambia el día sin cargar datos, se indica.

## Funciones implementadas

- Consultar calendarios configurados en el iPhone.
- Crear, mover, renombrar y eliminar citas puntuales.
- Cambiar ubicación, notas, duración y avisos.
- Buscar huecos por duración y franja; elegir una opción en el siguiente turno y comprobar otra vez la ocupación antes de reservar.
- Aclarar datos ausentes y resolver referencias a las citas realmente mostradas.
- Comprobar solapes y permitirlos solo cuando se pide expresamente.
- Deshacer el último cambio de la sesión si la cita no ha cambiado después.
- Abrir la ficha nativa de Calendario para cambios en series o citas con invitados.

Los cambios se preparan y validan antes de guardarse. Consultar opciones y efectuar un cambio basado en ellas requiere dos turnos; así se evita utilizar opciones antiguas.

Las citas se guardan en Calendario; la sincronización depende de la cuenta configurada. El historial de conversación, las opciones y deshacer duran la sesión, no persisten tras reiniciar la app.

## Voz local

SFSpeechRecognizer se configura para reconocer español en el dispositivo y se comprueba su disponibilidad. FoundationModels interpreta la petición con el modelo local de Apple Intelligence. El proyecto no incorpora claves de OpenAI, API remota, servidor ni suscripción de IA.

La escucha es visible y acotada. Una transcripción parcial, duplicada, inesperadamente final, interrumpida o con error no se convierte en una orden automática. El texto dudoso queda para revisar o volver a decirlo. La detección de fin combina actividad acústica y estabilidad de la transcripción; necesita calibración con el micrófono real.

La voz y la interpretación pueden equivocarse. El código valida fechas y referencias; no garantiza entender cualquier frase ni realiza reservas de restaurantes, compras o búsquedas externas.

## Estado comprobado

Swift 6.2 en Linux ha compilado y ejecutado las pruebas del núcleo en Europe/Madrid y UTC. Se ha comprobado la sintaxis Swift y la estructura de permisos/proyecto.

Esto no compila SwiftUI, Speech, AVFoundation, EventKit, WidgetKit ni las macros FoundationModels contra el SDK de iOS. La compilación completa, el renderizado de esta versión, los permisos del widget, la voz y las modificaciones reales de Calendario siguen pendientes.

El registro reproducible está en VERIFICACION.txt. Los casos de dispositivo están en Tests/Pruebas-en-iPhone.md. No se han leído ni modificado citas personales durante estas comprobaciones.

## Siguiente paso en el Mac

1. Instalar Xcode completo; Command Line Tools no basta.
2. Desde esta carpeta, ejecutar `python3 verify.py --ios`. Exige una compilación correcta para simulador.
3. Abrir MiAgenda.xcodeproj, seleccionar el esquema MiAgenda y elegir el equipo de firma en los objetivos MiAgenda y MiAgendaWidget.
4. Conectar el iPhone y ejecutar en él. Xcode indicará si hay que activar el modo de desarrollador.
5. Activar Apple Intelligence y permitir que termine de preparar el modelo. Conectar Calendario en la app y conceder los permisos de voz al abrir el asistente.
6. Probar con un calendario y citas ficticias siguiendo Tests/Pruebas-en-iPhone.md.
7. Añadir el widget grande Agenda desde la pantalla de Inicio.

La instalación permanente no queda resuelta por entregar este código. El equipo de firma y el método de distribución se configuran en Xcode.

## Desarrollo

Sin dependencias externas. Regenerar con `python3 make_project.py`. Pruebas: `python3 verify.py`. Compilación iOS: `python3 verify.py --ios`.

Las comprobaciones usan eventos ficticios y no piden acceso al calendario ni al micrófono.
