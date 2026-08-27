from __future__ import annotations

import csv
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / 'Data'
OUT = DATA_DIR / 'maintenance_tickets.csv'
CHALLENGE = DATA_DIR / 'challenge_test.csv'
SEED = 6035
TARGET_ROWS = 60_000
random.seed(SEED)

# The dataset is project-created and covers the maintenance categories implemented in HelaFixIt AI.
# Four language styles are balanced equally to support English, Sinhala, Singlish and mixed-language tickets.

CAT = {
    'Electrical': ('Electrician', ['Socket','Switch','Wiring','Circuit breaker','Distribution board'], ['Bedroom','Kitchen','Common Corridor','Electrical Room']),
    'Plumbing': ('Plumber', ['Water pipe','Tap','Toilet','Shower','Water tank line'], ['Bathroom','Kitchen','Bedroom']),
    'Lift': ('Lift Technician', ['Passenger lift','Lift door','Lift panel','Lift motor'], ['Lift Lobby','Common Corridor']),
    'Air Conditioning': ('AC Technician', ['Split AC','AC compressor','AC fan','Thermostat'], ['Bedroom','Living Room','Lobby']),
    'Drainage': ('Plumber', ['Floor drain','Sewer line','Manhole','Rainwater drain'], ['Bathroom','Parking Basement','Garden','Common Corridor']),
    'Cleaning': ('Cleaner', ['Common floor','Waste area','Lobby floor','Staircase'], ['Lobby','Common Corridor','Staircase','Garbage Room']),
    'Pest Control': ('Pest Controller', ['Kitchen area','Garbage room','Balcony','Common area'], ['Kitchen','Garbage Room','Balcony','Garden']),
    'Carpentry': ('Carpenter', ['Door','Window','Cupboard','Door frame','Handrail'], ['Bedroom','Lobby','Staircase']),
    'Fire and Safety': ('Fire and Safety Technician', ['Fire alarm','Smoke detector','Fire extinguisher','Common area'], ['Bedroom','Kitchen','Lobby','Common Corridor']),
    'Gas': ('Gas Technician', ['Gas line','Gas valve','Gas appliance','Gas meter'], ['Kitchen','Service Area']),
    'Structural': ('Building Technician', ['Wall','Ceiling','Roof','Balcony slab','Column'], ['Bedroom','Living Room','Balcony','Parking Basement']),
    'Security and Access': ('Security Technician', ['Main door','Access gate','Access card reader','Intercom','Security lock'], ['Lobby','Entrance','Parking']),
    'Other': ('General Maintenance', ['Common fitting','General fixture','Signage','Shared facility'], ['Lobby','Common Corridor','Garden']),
}

SCENARIOS = {
'Electrical': [
 ('Low','The corridor light is flickering','corridor light eka flicker wenawa','කොරිඩෝර් ලයිට් එක දිලිසෙනවා','corridor light එක flicker වෙනවා','Lighting fault'),
 ('Medium','The wall socket is not working','wall socket eka wada naha','බිත්ති සොකට් එක වැඩ කරන්නේ නැහැ','wall socket එක වැඩ කරන්නේ නැහැ','Socket fault'),
 ('High','The circuit breaker keeps tripping','breaker eka aye aye trip wenawa','සර්කිට් බ්‍රේකර් එක නැවත නැවත ට්‍රිප් වෙනවා','breaker එක repeatedly trip වෙනවා','Breaker fault'),
 ('Emergency','Sparks are coming from the socket','socket eken spark enawa','සොකට් එකෙන් ගිනි පුපුරු එනවා','socket එකෙන් spark එනවා','Electrical sparking'),
 ('Emergency','I received an electric shock from the switch','switch eka alladdi current waduna','ස්විච් එක අල්ලද්දී විදුලි සැර වැදුනා','switch එක touch කරද්දී shock එකක් වැදුනා','Electric shock'),
 ('Emergency','Water is reaching the electrical panel','watura electrical panel langata enawa','වතුර විදුලි පුවරුව ළඟට එනවා','water එක electrical panel එක ළඟට එනවා','Water near electricity'),
],
'Plumbing': [
 ('Low','The bathroom tap has a slow drip','bathroom tap eken poddak watura leak wenawa','බාත්රූම් ටැප් එකෙන් වතුර ටික ටික කාන්දු වෙනවා','bathroom tap එකෙන් පොඩි water leak එකක්','Small leak'),
 ('Medium','The toilet is not flushing properly','toilet eka hariyata flush wenne naha','වැසිකිළිය හරියට ෆ්ලෂ් වෙන්නේ නැහැ','toilet එක properly flush වෙන්නේ නැහැ','Toilet fault'),
 ('High','A large water leak is spreading across the floor','loku watura leak ekak floor eka pura yanawa','විශාල වතුර කාන්දුවක් බිම පුරා පැතිරෙනවා','large water leak එක floor එක පුරා යනවා','Major leak'),
 ('Emergency','A water pipe has burst and water is pouring out','water pipe eka pupurala watura godak galanawa','වතුර පයිප්පය පුපුරලා වතුර ගොඩක් ගලනවා','water pipe එක burst වෙලා water ගොඩක් එනවා','Burst pipe'),
 ('Emergency','Very hot water is spraying from the pipe','pipe eken godak rath watura enawa','පයිප්පයෙන් ඉතා උණු වතුර විදිනවා','pipe එකෙන් very hot water spray වෙනවා','Hot water hazard'),
],
'Lift': [
 ('Low','The lift floor display is not showing correctly','lift display eka hariyata pennanne naha','ලිෆ්ට් මහල් දර්ශකය හරියට පෙන්වන්නේ නැහැ','lift display එක හරියට show වෙන්නේ නැහැ','Lift display'),
 ('Medium','The lift door is not closing properly','lift door eka hariyata close wenne naha','ලිෆ්ට් දොර හරියට වැහෙන්නේ නැහැ','lift door එක properly close වෙන්නේ නැහැ','Lift door'),
 ('High','The lift is making a severe mechanical noise','lift eken loku mechanical sound ekak enawa','ලිෆ්ට් එකෙන් දැඩි යාන්ත්‍රික ශබ්දයක් එනවා','lift එකෙන් severe mechanical sound එකක් එනවා','Lift mechanical fault'),
 ('Emergency','A person is trapped inside the lift','kenek lift eke athule hira wela','කෙනෙක් ලිෆ්ට් එක ඇතුළේ හිරවෙලා','person කෙනෙක් lift එක ඇතුළේ stuck','Lift entrapment'),
 ('Emergency','The lift suddenly dropped down','lift eka uda idan bimata kadan watila','ලිෆ්ට් එක හදිසියේ පහළට වැටුණා','lift එක suddenly පහළට dropped','Lift drop'),
 ('Emergency','The lift is moving while the door is open','lift eka yanakota door eka open','ලිෆ්ට් එක යනකොට දොර ඇරලා තියෙනවා','lift එක move වෙද්දී door open','Dangerous lift door'),
],
'Air Conditioning': [
 ('Low','The AC remote is not responding','ac remote eka response karanne naha','ඒසී රිමෝට් එක ප්‍රතිචාර දක්වන්නේ නැහැ','AC remote එක response කරන්නේ නැහැ','AC remote'),
 ('Medium','The air conditioner is not cooling properly','ac eka hariyata cool wenne naha','ඒසී එක හරියට සිසිල් කරන්නේ නැහැ','AC එක properly cool වෙන්නේ නැහැ','AC cooling'),
 ('High','A large amount of water is leaking from the AC','ac eken watura godak leak wenawa','ඒසී එකෙන් වතුර ගොඩක් කාන්දු වෙනවා','AC එකෙන් water ගොඩක් leak වෙනවා','AC water leak'),
 ('Emergency','Smoke is coming from the air conditioner','ac eken duma enawa','ඒසී එකෙන් දුම එනවා','AC එකෙන් smoke එනවා','AC smoke'),
 ('Emergency','The AC unit is sparking and smells burnt','ac unit eken spark enawa saha burning smell ekak','ඒසී යුනිට් එකෙන් ගිනි පුපුරු එනවා සහ පිළිස්සුන ගඳක් තියෙනවා','AC unit එකෙන් spark සහ burning smell එනවා','AC electrical hazard'),
],
'Drainage': [
 ('Low','The balcony drain is slow','balcony drain eka slow','බැල්කනි ඩ්‍රේන් එකෙන් වතුර මන්දගාමීව බැස යනවා','balcony drain එක slow','Slow drain'),
 ('Medium','The kitchen drain is blocked','kitchen drain eka block wela','කුස්සියේ ඩ්‍රේන් එක අවහිර වෙලා','kitchen drain එක blocked','Blocked drain'),
 ('High','Sewage is overflowing from the drain','drain eken sewage overflow wenawa','ඩ්‍රේන් එකෙන් මළ ජලය උඩට එනවා','drain එකෙන් sewage overflow වෙනවා','Sewage overflow'),
 ('High','The basement is flooding because the drain is blocked','basement eka watura pirila drain eka block','බේස්මන්ට් එක වතුරෙන් පිරිලා ඩ්‍රේන් එක අවහිරයි','basement එක flooded because drain එක blocked','Basement flooding'),
 ('Emergency','Sewage water is entering an occupied room','sewage watura room ekata enawa','මළ ජලය නේවාසික කාමරයට ඇතුල් වෙනවා','sewage water එක room එකට එනවා','Severe sewage'),
],
'Cleaning': [
 ('Low','The common corridor needs cleaning','common corridor eka clean karanna one','පොදු කොරිඩෝර් එක පිරිසිදු කරන්න ඕනේ','common corridor එක clean කරන්න ඕනේ','Routine cleaning'),
 ('Medium','There is a large slippery spill on the floor','floor eke slippery spill ekak thiyenawa','බිම ලිස්සන දියරයක් පැතිරලා තියෙනවා','floor එකේ slippery spill එකක්','Slip hazard'),
 ('High','Broken glass pieces are spread across the floor','glass kadila bimata katu thiyenawa','කැඩුණු වීදුරු කැබලි බිම පුරා තියෙනවා','broken glass කැබලි floor එකේ','Broken glass'),
 ('Emergency','A chemical spill is blocking the walkway','chemical spill ekak walkway eka block karala','රසායනික ද්‍රව්‍ය බිම වැටී මාර්ගය අවහිර වෙලා','chemical spill එක walkway එක block කරලා','Chemical spill'),
 ('High','A used needle and blood are on the floor','used needle ekak saha blood floor eke','භාවිත කළ ඉඳිකටුවක් සහ රුධිරය බිම තියෙනවා','used needle එකක් සහ blood floor එකේ','Biohazard'),
],
'Pest Control': [
 ('Low','There are ants near the kitchen window','kitchen window langa ants innawa','කුස්සියේ ජනේලය අසල කුහුඹුවන් ඉන්නවා','kitchen window එක ළඟ ants ඉන්නවා','Ants'),
 ('Medium','There are many cockroaches in the kitchen','kitchen eke cockroaches godak innawa','කුස්සියේ කැරපොත්තන් ගොඩක් ඉන්නවා','kitchen එකේ cockroaches ගොඩක්','Cockroaches'),
 ('High','There are many rats in the garbage room','garbage room eke rats godak innawa','කසළ කාමරයේ මීයන් ගොඩක් ඉන්නවා','garbage room එකේ rats ගොඩක්','Rat infestation'),
 ('Emergency','A snake is inside the occupied common area','snake ekak common area eke innawa','පොදු ප්‍රදේශයේ සර්පයෙක් ඉන්නවා','snake එකක් common area එකේ','Snake'),
 ('High','An aggressive bee swarm is close to residents','bee swarm ekak residents langa','මී මැසි රංචුවක් නේවාසිකයන් අසල තියෙනවා','bee swarm එකක් residents ළඟ','Bee swarm'),
],
'Carpentry': [
 ('Low','The cupboard hinge is loose','cupboard hinge eka loose','කබඩ් හින්ජ් එක ලූස් වෙලා','cupboard hinge එක loose','Loose hinge'),
 ('Medium','The bedroom door will not close properly','bedroom door eka hariyata wahanna ba','නිදන කාමරයේ දොර හරියට වැහෙන්නේ නැහැ','bedroom door එක properly close වෙන්නේ නැහැ','Door fault'),
 ('High','The heavy door frame may fall','door frame eka watenna wage loose','බර දොර රාමුව වැටෙන්න වගේ ලූස් වෙලා','heavy door frame එක fall වෙන්න වගේ','Falling frame'),
 ('High','The staircase handrail is loose and unsafe','staircase handrail eka godak loose','පඩිපෙළ අත්පාවරුව ගොඩක් ලූස්','staircase handrail එක unsafe ලෙස loose','Handrail hazard'),
],
'Fire and Safety': [
 ('Emergency','There is smoke smell coming from the room','kamarekin smoke smell ekak enawa','කාමරයෙන් දුම් ගඳක් එනවා','room එකෙන් smoke smell එකක් එනවා','Smoke smell'),
 ('Emergency','A room is catching fire','kamarayak gini gannawa','කාමරයක ගින්නක් ඇතිවෙලා','room එකක් fire වෙලා','Fire'),
 ('High','The fire alarm is not working','fire alarm eka wada naha','ගිනි අනතුරු ඇඟවීමේ පද්ධතිය වැඩ කරන්නේ නැහැ','fire alarm එක වැඩ කරන්නේ නැහැ','Fire alarm fault'),
 ('High','The smoke detector is showing a fault','smoke detector eka faulty','දුම් සංවේදකයේ දෝෂයක් තියෙනවා','smoke detector එක faulty','Smoke detector fault'),
 ('High','The fire extinguisher is damaged or empty','fire extinguisher eka damage wela','ගිනි නිවන උපකරණය හානි වෙලා හෝ හිස්','fire extinguisher එක damaged','Fire extinguisher fault'),
],
'Gas': [
 ('Emergency','There is a strong gas smell in the kitchen','kitchen eke loku gas smell ekak enawa','කුස්සියේ දැඩි ගෑස් ගඳක් එනවා','kitchen එකේ strong gas smell එකක්','Gas smell'),
 ('Emergency','Gas is leaking from the valve','gas valve eken leak ekak enawa','ගෑස් වෑල්වයෙන් කාන්දුවක් තියෙනවා','gas valve එකෙන් leak වෙනවා','Gas leak'),
 ('High','The gas valve is not closing properly','gas valve eka hariyata close wenne naha','ගෑස් වෑල්වය හරියට වැහෙන්නේ නැහැ','gas valve එක properly close වෙන්නේ නැහැ','Gas valve fault'),
],
'Structural': [
 ('Low','There is a small surface crack on the wall','wall eke podi crack ekak thiyenawa','බිත්තියේ පොඩි මතුපිට ඉරිතැලීමක් තියෙනවා','wall එකේ small crack එකක්','Minor crack'),
 ('High','A large crack has appeared in the wall','wall eke loku crack ekak enawa','බිත්තියේ විශාල ඉරිතැලීමක් ඇතිවෙලා','wall එකේ large crack එකක්','Major crack'),
 ('Emergency','Part of the ceiling is falling down','ceiling eken kotas bimata watenawa','සිවිලිමේ කොටස් පහළට වැටෙනවා','ceiling එකේ parts පහළට fall වෙනවා','Falling ceiling'),
 ('Emergency','The balcony slab has a severe crack and is moving','balcony slab eke loku crack ekak saha move wenawa','බැල්කනි ස්ලැබ් එකේ දැඩි ඉරිතැලීමක් සහ චලනයක් තියෙනවා','balcony slab එක severe crack සහ movement','Structural danger'),
 ('High','Water is entering through a damaged roof','roof eka damage wela watura enawa','වහලයට හානි වෙලා වතුර ඇතුල් වෙනවා','damaged roof එකෙන් water එනවා','Roof damage'),
],
'Security and Access': [
 ('Low','The intercom is not working','intercom eka wada naha','ඉන්ටර්කොම් එක වැඩ කරන්නේ නැහැ','intercom එක වැඩ කරන්නේ නැහැ','Intercom fault'),
 ('Medium','The access card reader is not responding','access card reader eka response karanne naha','ප්‍රවේශ කාඩ් කියවනය ප්‍රතිචාර දක්වන්නේ නැහැ','access card reader එක response කරන්නේ නැහැ','Access reader'),
 ('High','The main security door cannot be locked','main security door eka lock karanna ba','ප්‍රධාන ආරක්ෂක දොර ලොක් කරන්න බැහැ','main security door එක lock කරන්න බැහැ','Security door'),
 ('High','The parking gate is stuck open','parking gate eka open wela stuck','පාර්කින් ගේට්ටුව ඇරී හිරවෙලා','parking gate එක open වෙලා stuck','Gate fault'),
 ('Emergency','The emergency exit door is locked and cannot open','emergency exit door eka lock wela arinne naha','හදිසි පිටවීමේ දොර ලොක් වෙලා ඇරෙන්නේ නැහැ','emergency exit door එක locked සහ open වෙන්නේ නැහැ','Blocked emergency exit'),
],
'Other': [
 ('Low','A common area sign is loose','common area sign eka loose','පොදු ප්‍රදේශයේ සලකුණ ලූස් වෙලා','common area sign එක loose','Loose sign'),
 ('Medium','A shared facility fitting is not working','shared facility fitting eka wada naha','පොදු පහසුකමක උපකරණයක් වැඩ කරන්නේ නැහැ','shared facility fitting එක work වෙන්නේ නැහැ','General maintenance'),
 ('High','A heavy object is loose above the walkway','walkway uda heavy object ekak loose','ගමන් මාර්ගයට ඉහළින් බර වස්තුවක් ලූස් වෙලා','walkway එක උඩ heavy object එක loose','Falling object'),
],
}


# Additional realistic residential maintenance cases. These expand the vocabulary and
# issue coverage without creating extra system categories that would be difficult to explain.
EXTRA_SCENARIOS = {
'Electrical': [
 ('Medium','The ceiling fan is not working','ceiling fan eka wada naha','සිවිලිම් පංකාව වැඩ කරන්නේ නැහැ','ceiling fan එක වැඩ කරන්නේ නැහැ','Ceiling fan fault'),
 ('High','The whole apartment has lost electrical power','apartment eke current naha','මුළු අපාර්ට්මෙන්ට් එකේම විදුලිය නැහැ','apartment එකේම power නැහැ','Apartment power outage'),
 ('High','The distribution board smells burnt','distribution board eken burning smell ekak enawa','විදුලි පුවරුවෙන් පිළිස්සුන ගඳක් එනවා','distribution board එකෙන් burning smell එකක්','Electrical burning smell'),
 ('Emergency','A live wire is exposed near the floor','live wire ekak floor langa eliyata thiyenawa','විදුලි වයර් එකක් බිම අසල නිරාවරණව තියෙනවා','live wire එක floor එක ළඟ exposed','Exposed live wire'),
 ('High','The socket is very hot when used','socket eka use karaddi godak rath wenawa','සොකට් එක භාවිතා කරද්දී ගොඩක් රත් වෙනවා','socket එක use කරද්දී very hot','Hot socket'),
],
'Plumbing': [
 ('Medium','There is no water from the bathroom taps','bathroom tap walin watura enne naha','බාත්රූම් ටැප් වලින් වතුර එන්නේ නැහැ','bathroom taps වලින් water එන්නේ නැහැ','No water supply'),
 ('Low','The water pressure is very low','watura pressure eka godak adui','වතුර පීඩනය ගොඩක් අඩුයි','water pressure එක very low','Low water pressure'),
 ('High','The toilet is overflowing onto the floor','toilet eka overflow wela floor ekata yanawa','වැසිකිළිය උතුරලා බිමට වතුර යනවා','toilet එක overflow වෙලා floor එකට යනවා','Overflowing toilet'),
 ('High','The water tank line is leaking heavily','water tank line eken loku leak ekak','වතුර ටැංකි නළයෙන් විශාල කාන්දුවක් තියෙනවා','water tank line එකෙන් heavy leak එකක්','Tank line leak'),
 ('Medium','The shower pipe is leaking inside the wall','shower pipe eka wall athule leak wenawa','ෂවර් නළය බිත්තිය ඇතුළේ කාන්දු වෙනවා','shower pipe එක wall ඇතුළේ leak වෙනවා','Hidden shower leak'),
],
'Lift': [
 ('Medium','The lift does not stop level with the floor','lift eka floor level ekata stop wenne naha','ලිෆ්ට් එක මහලට සමාන මට්ටමක නවත්වන්නේ නැහැ','lift එක floor level එකට stop වෙන්නේ නැහැ','Lift levelling fault'),
 ('High','The lift is jerking strongly while moving','lift eka yaddi godak jerk wenawa','ලිෆ්ට් එක යනකොට දැඩි ලෙස ගැස්සෙනවා','lift එක move වෙද්දී strong jerking','Lift jerking'),
 ('High','The lift alarm button is not working','lift alarm button eka wada naha','ලිෆ්ට් අනතුරු ඇඟවීමේ බොත්තම වැඩ කරන්නේ නැහැ','lift alarm button එක වැඩ කරන්නේ නැහැ','Lift alarm fault'),
 ('Medium','The lift call button is not responding','lift call button eka response karanne naha','ලිෆ්ට් කැඳවීමේ බොත්තම ප්‍රතිචාර දක්වන්නේ නැහැ','lift call button එක response කරන්නේ නැහැ','Lift call button'),
 ('Emergency','The lift is moving unusually fast downward','lift eka godak fast pahala yanawa','ලිෆ්ට් එක අසාමාන්‍ය ලෙස වේගයෙන් පහළට යනවා','lift එක unusually fast පහළට යනවා','Uncontrolled lift movement'),
],
'Air Conditioning': [
 ('Medium','The AC does not turn on','ac eka on wenne naha','ඒසී එක ක්‍රියාත්මක වෙන්නේ නැහැ','AC එක on වෙන්නේ නැහැ','AC power fault'),
 ('Medium','Ice is forming on the AC indoor unit','ac indoor unit eke ice hadenawa','ඒසී ඇතුළත යුනිට් එකේ අයිස් හැදෙනවා','AC indoor unit එකේ ice form වෙනවා','AC icing'),
 ('High','The AC is making a loud compressor noise','ac compressor eken loku sound ekak enawa','ඒසී කොම්ප්‍රෙසර් එකෙන් දැඩි ශබ්දයක් එනවා','AC compressor එකෙන් loud noise එකක්','AC compressor noise'),
 ('High','There is a strong chemical smell from the AC','ac eken chemical smell ekak enawa','ඒසී එකෙන් දැඩි රසායනික ගඳක් එනවා','AC එකෙන් strong chemical smell එකක්','AC chemical smell'),
 ('Medium','The AC drain pipe keeps dripping indoors','ac drain pipe eken athulata watura drip wenawa','ඒසී ඩ්‍රේන් නළයෙන් ඇතුළට වතුර ටික ටික එනවා','AC drain pipe එකෙන් indoor water drip වෙනවා','AC drain leak'),
],
'Drainage': [
 ('Medium','There is a bad sewage smell from the drain','drain eken sewage gandha enawa','ඩ්‍රේන් එකෙන් මළ ජල ගඳක් එනවා','drain එකෙන් sewage smell එකක් එනවා','Drain odour'),
 ('High','The roof rainwater drain is overflowing','roof rainwater drain eka overflow wenawa','වහලේ වැසි වතුර ඩ්‍රේන් එක උතුරනවා','roof rainwater drain එක overflow වෙනවා','Roof drain overflow'),
 ('High','The manhole cover is broken and open','manhole cover eka kadila open wela','මෑන්හෝල් ආවරණය කැඩිලා විවෘතව තියෙනවා','manhole cover එක broken සහ open','Open manhole'),
 ('Medium','The bathroom floor drain is backing up','bathroom floor drain eken watura uda enawa','බාත්රූම් බිම් ඩ්‍රේන් එකෙන් වතුර නැවත උඩට එනවා','bathroom floor drain එක back up වෙනවා','Drain backup'),
 ('High','Storm water is entering the parking basement','rain watura parking basement ekata enawa','වැසි වතුර පාර්කින් බේස්මන්ට් එකට ඇතුල් වෙනවා','storm water එක parking basement එකට එනවා','Storm water flooding'),
],
'Cleaning': [
 ('Low','Garbage has not been collected from the common area','common area garbage collect karala naha','පොදු ප්‍රදේශයේ කසළ එකතු කරලා නැහැ','common area garbage collect කරලා නැහැ','Garbage collection'),
 ('Medium','There is mould growing on a damp common wall','common wall eke mould hadila','තෙත් පොදු බිත්තියේ පුස් හැදිලා','damp common wall එකේ mould තියෙනවා','Mould cleaning'),
 ('Medium','Oil has spilled on the parking floor','parking floor eke oil spill wela','පාර්කින් බිමට තෙල් වැටිලා තියෙනවා','parking floor එකේ oil spill වෙලා','Oil spill'),
 ('High','There is vomit and biological waste in the corridor','corridor eke biological waste thiyenawa','කොරිඩෝර් එකේ ජෛව අපද්‍රව්‍ය තියෙනවා','corridor එකේ biological waste තියෙනවා','Biological contamination'),
 ('Low','The staircase is very dusty and dirty','staircase eka godak dirty','පඩිපෙළ ගොඩක් දූවිලි සහ අපිරිසිදුයි','staircase එක very dusty and dirty','Staircase cleaning'),
],
'Pest Control': [
 ('Medium','There are many mosquitoes near stagnant water','watura ekathu wela mosquitoes godak innawa','වතුර රැඳී ඇති තැන මදුරුවන් ගොඩක් ඉන්නවා','stagnant water ළඟ mosquitoes ගොඩක්','Mosquito problem'),
 ('Medium','Bedbugs are reported inside the bedroom','bedroom eke bedbugs innawa','නිදන කාමරයේ ඇඳ මකුණන් ඉන්නවා','bedroom එකේ bedbugs තියෙනවා','Bedbug problem'),
 ('High','Termites are damaging a wooden door frame','termite la door frame eka kanawa','වේයන් ලී දොර රාමුවට හානි කරනවා','termites door frame එක damage කරනවා','Termite damage'),
 ('Medium','A wasp nest is near the balcony','balcony langa wasp nest ekak','බැල්කනිය අසල බඹර කූඩුවක් තියෙනවා','balcony ළඟ wasp nest එකක්','Wasp nest'),
 ('Low','Small insects are appearing around the kitchen cupboards','kitchen cupboard langa podi insects innawa','කුස්සියේ කබඩ් අසල පොඩි කෘමීන් ඉන්නවා','kitchen cupboards ළඟ small insects තියෙනවා','Small insect problem'),
],
'Carpentry': [
 ('Medium','The window frame is damaged and will not close','window frame eka damage wela close wenne naha','ජනේල රාමුව හානිවෙලා වැහෙන්නේ නැහැ','window frame එක damaged සහ close වෙන්නේ නැහැ','Window frame fault'),
 ('Low','A wooden shelf is loose','wooden shelf eka loose','ලී රාක්කයක් ලූස් වෙලා','wooden shelf එක loose','Loose shelf'),
 ('Medium','The cupboard door is broken','cupboard door eka kadila','කබඩ් දොර කැඩිලා','cupboard door එක broken','Cupboard door'),
 ('High','A wall mounted wooden cabinet is coming loose','wall cabinet eka galawenna wage','බිත්තියට සවි කළ ලී කබඩ් එක ගැලවෙන්න වගේ','wall cabinet එක coming loose','Loose wall cabinet'),
 ('Medium','The wooden main door is scraping and cannot close','wooden main door eka floor eke galila close wenne naha','ලී ප්‍රධාන දොර බිමට ගැටී වැහෙන්නේ නැහැ','wooden main door එක scrape වෙලා close වෙන්නේ නැහැ','Wooden door fault'),
],
'Fire and Safety': [
 ('High','The emergency light is not working','emergency light eka wada naha','හදිසි ආලෝකය වැඩ කරන්නේ නැහැ','emergency light එක වැඩ කරන්නේ නැහැ','Emergency light fault'),
 ('High','The fire hose reel cabinet is damaged','fire hose reel cabinet eka damage wela','ගිනි හෝස් රීල් කබඩ් එක හානිවෙලා','fire hose reel cabinet එක damaged','Fire hose reel fault'),
 ('Emergency','Smoke is filling the common corridor','common corridor eka duma walin pirenawa','පොදු කොරිඩෝර් එක දුමෙන් පිරෙනවා','common corridor එක smoke වලින් fill වෙනවා','Heavy smoke'),
 ('High','The fire alarm keeps showing a system fault','fire alarm eke system fault ekak pennanawa','ගිනි අනතුරු ඇඟවීමේ පද්ධතියේ දෝෂයක් පෙන්වනවා','fire alarm එක system fault show කරනවා','Fire alarm system fault'),
 ('High','The fire extinguisher inspection date has expired','fire extinguisher date eka expire wela','ගිනි නිවන උපකරණයේ පරීක්ෂණ දිනය කල් ඉකුත් වෙලා','fire extinguisher inspection date එක expired','Extinguisher expired'),
],
'Gas': [
 ('Emergency','The gas hose is cracked and leaking','gas hose eka crack wela leak wenawa','ගෑස් හෝස් එක ඉරිතැලිලා කාන්දු වෙනවා','gas hose එක cracked and leaking','Gas hose leak'),
 ('High','The gas stove flame is unusually yellow','gas stove flame eka yellow wela','ගෑස් ලිපේ ගිනි දැල්ල අසාමාන්‍ය ලෙස කහ පාටයි','gas stove flame එක unusually yellow','Abnormal gas flame'),
 ('Emergency','The gas valve is stuck open','gas valve eka open wela stuck','ගෑස් වෑල්වය විවෘතව හිරවෙලා','gas valve එක stuck open','Gas valve stuck open'),
 ('High','The gas meter is making an unusual noise','gas meter eken unusual sound ekak','ගෑස් මීටරයෙන් අසාමාන්‍ය ශබ්දයක් එනවා','gas meter එකෙන් unusual noise එකක්','Gas meter noise'),
 ('Emergency','There is a gas smell near the cylinder connection','cylinder connection langa gas smell ekak','ගෑස් සිලින්ඩර් සම්බන්ධතාවය අසල ගෑස් ගඳක් එනවා','cylinder connection එක ළඟ gas smell එකක්','Cylinder gas smell'),
],
'Structural': [
 ('Medium','Damp patches are spreading on the wall','wall eke damp patch wadi wenawa','බිත්තියේ තෙත් පැල්ලම් පැතිරෙනවා','wall එකේ damp patches spread වෙනවා','Wall dampness'),
 ('High','Plaster is falling from the ceiling','ceiling plaster bimata watenawa','සිවිලිමේ ප්ලාස්ටර් කැබලි පහළට වැටෙනවා','ceiling plaster එක fall වෙනවා','Falling plaster'),
 ('High','A balcony railing fixing is loose in the concrete','balcony railing fixing eka concrete eken loose','බැල්කනි අත්පාවරුවේ සවි කිරීම කොන්ක්‍රීට් එකෙන් ලූස් වෙලා','balcony railing fixing එක concrete එකෙන් loose','Railing structural fixing'),
 ('Medium','Several roof tiles are broken','roof tiles kihipayak kadila','වහලේ ටයිල් කිහිපයක් කැඩිලා','several roof tiles broken','Broken roof tiles'),
 ('High','A column has a new deep crack','column eke aluth deep crack ekak','කොලමක අලුත් ගැඹුරු ඉරිතැලීමක් තියෙනවා','column එකේ new deep crack එකක්','Column crack'),
],
'Security and Access': [
 ('Medium','The visitor intercom cannot call the apartment','visitor intercom eken apartment ekata call wenne naha','අමුත්තන්ගේ ඉන්ටර්කොම් එකෙන් අපාර්ට්මෙන්ට් එකට ඇමතුම් යන්නේ නැහැ','visitor intercom එකෙන් apartment එකට call වෙන්නේ නැහැ','Visitor intercom'),
 ('High','The entrance door lock is broken','entrance door lock eka kadila','ප්‍රවේශ දොරේ ලොක් එක කැඩිලා','entrance door lock එක broken','Entrance lock'),
 ('High','The access gate opens without a valid card','access gate eka card nathuwa open wenawa','ප්‍රවේශ ගේට්ටුව වලංගු කාඩ් එකක් නැතුව ඇරෙනවා','access gate එක valid card නැතුව open වෙනවා','Access control failure'),
 ('Medium','The parking barrier does not open','parking barrier eka open wenne naha','පාර්කින් බාධකය ඇරෙන්නේ නැහැ','parking barrier එක open වෙන්නේ නැහැ','Parking barrier'),
 ('High','The main entrance is stuck open at night','main entrance eka raatriye open wela stuck','ප්‍රධාන පිවිසුම රාත්‍රියේ විවෘතව හිරවෙලා','main entrance එක night time open වෙලා stuck','Entrance security risk'),
],
'Other': [
 ('Low','The apartment notice board is damaged','notice board eka damage wela','අපාර්ට්මෙන්ට් දැන්වීම් පුවරුව හානිවෙලා','notice board එක damaged','Notice board'),
 ('Medium','A common area bench is broken','common area bench eka kadila','පොදු ප්‍රදේශයේ බංකුවක් කැඩිලා','common area bench එක broken','Broken bench'),
 ('Medium','A mailbox door is damaged','mailbox door eka damage wela','තැපැල් පෙට්ටි දොර හානිවෙලා','mailbox door එක damaged','Mailbox fault'),
 ('High','A metal sign bracket is loose above the entrance','entrance uda metal sign bracket eka loose','පිවිසුමට ඉහළින් ලෝහ සලකුණු සවිකිරීම ලූස් වෙලා','entrance එක උඩ metal sign bracket එක loose','Loose overhead sign'),
 ('Medium','A shared drying rack is broken','shared drying rack eka kadila','පොදු වියළන රාක්කය කැඩිලා','shared drying rack එක broken','Shared fitting fault'),
],
}
for _category, _items in EXTRA_SCENARIOS.items():
    SCENARIOS[_category].extend(_items)

PREFIX = {
 'English':['Please check this issue','Resident reported','Maintenance request','Please attend to this problem','This started today','This needs attention'],
 'Singlish':['please balanna','me issue eka balanna','ikmanata check karanna','maintenance ekata danawa','ada idan meka thiyenawa','me problem eka balanna'],
 'Sinhala':['කරුණාකර මේ ගැටලුව බලන්න','නේවාසිකයා වාර්තා කළේ','නඩත්තු ඉල්ලීම','මේ ගැටලුවට අවධානය දෙන්න','අද සිට මේක තියෙනවා','කරුණාකර පරීක්ෂා කරන්න'],
 'Mixed':['please මේ issue එක බලන්න','maintenance request එක','මේ problem එක check කරන්න','resident reported මේ issue එක','please ඉක්මනට check කරන්න','today ඉඳන් මේක තියෙනවා'],
}
SUFFIX = {
 'English':['in the apartment','near the common area','and it is getting worse','please arrange maintenance','during normal use','at the reported location'],
 'Singlish':['apartment eke','common area langa','dan tikak wadi wela','repair karanna','normal use karaddi','me location eke'],
 'Sinhala':['අපාර්ට්මෙන්ට් එකේ','පොදු ප්‍රදේශය අසල','දැන් ටිකක් වැඩි වෙලා','අලුත්වැඩියා කරන්න','සාමාන්‍ය භාවිතයේදී','වාර්තා කළ ස්ථානයේ'],
 'Mixed':['apartment එකේ','common area එක ළඟ','දැන් issue එක වැඩි වෙලා','please repair කරන්න','normal use කරද්දී','reported location එකේ'],
}


PRIORITY_CONTEXT = {
 'English': {
   'Low':['It is a small issue and the item can still be used','There is no immediate danger but maintenance is needed','The problem is minor at the moment','It can be scheduled during normal maintenance','Only a small part is affected'],
   'Medium':['Normal use is affected and a repair is needed','The problem is continuing and should be checked soon','It is difficult to use normally','The issue should be attended within the normal maintenance queue','The fault is causing inconvenience but there is no immediate danger'],
   'High':['The problem is getting worse and needs quick attention','A larger area or several residents may be affected','The fault may cause more damage if it is delayed','Please arrange a technician as soon as possible','The issue has become serious and should be prioritised'],
   'Emergency':['There may be immediate danger to residents or property','This requires immediate attention for safety','Please respond now because the situation is dangerous','Do not delay this safety issue','Urgent help is required immediately']},
 'Singlish': {
   'Low':['podi issue ekak thama use karanna puluwan','immediate danger ekak naha namuth repair one','danata meka minor issue ekak','normal maintenance ekata schedule karanna puluwan','podi kotasak witharai affect wela'],
   'Medium':['normal use ekata awul repair ekak one','issue eka digatama thiyenawa ikmanin balanna','hariyata use karanna amarui','normal maintenance queue eken balanna one','inconvenience ekak thiyenawa namuth immediate danger naha'],
   'High':['issue eka ikmanata wadi wenawa quick attention one','loku area ekakata hari residents godakata affect wenna puluwan','delay unoth thawa damage wenna puluwan','technician kenek ikmanata ewanna','meka serious wela priority denna'],
   'Emergency':['residents lata hari property ekata immediate danger ekak','safety nisa danma balanna one','meka dangerous danma respond karanna','me safety issue eka delay karanna epa','urgent help danma one']},
 'Sinhala': {
   'Low':['මේක පොඩි ගැටලුවක් සහ තවම භාවිතා කරන්න පුළුවන්','හදිසි අවදානමක් නැහැ නමුත් නඩත්තුව අවශ්‍යයි','දැනට ගැටලුව සුළුයි','සාමාන්‍ය නඩත්තු කාලයට සකස් කළ හැකියි','පොඩි කොටසකට පමණක් බලපෑම තියෙනවා'],
   'Medium':['සාමාන්‍ය භාවිතයට බාධා ඇති නිසා අලුත්වැඩියාවක් අවශ්‍යයි','ගැටලුව දිගටම පවතින නිසා ඉක්මනින් පරීක්ෂා කරන්න','සාමාන්‍ය ලෙස භාවිතා කිරීමට අපහසුයි','සාමාන්‍ය නඩත්තු පෝලිමේ ඉක්මනින් බලන්න','අපහසුතාවයක් තියෙනවා නමුත් හදිසි අවදානමක් නැහැ'],
   'High':['ගැටලුව ඉක්මනින් වැඩි වෙමින් තියෙන නිසා ඉක්මන් අවධානය අවශ්‍යයි','විශාල ප්‍රදේශයකට හෝ නේවාසිකයන් කිහිප දෙනෙකුට බලපෑම් විය හැකියි','ප්‍රමාද වුවහොත් තවත් හානි විය හැකියි','තාක්ෂණිකයෙකු ඉක්මනින් යොදවන්න','ගැටලුව බරපතල නිසා ප්‍රමුඛතාව දෙන්න'],
   'Emergency':['නේවාසිකයන්ට හෝ දේපළට හදිසි අවදානමක් විය හැකියි','ආරක්ෂාව සඳහා වහාම අවධානය අවශ්‍යයි','තත්ත්වය අනතුරුදායක නිසා දැන්ම ප්‍රතිචාර දක්වන්න','මේ ආරක්ෂක ගැටලුව ප්‍රමාද කරන්න එපා','වහාම හදිසි උදව් අවශ්‍යයි']},
 'Mixed': {
   'Low':['මේක small issue එකක් සහ still use කරන්න පුළුවන්','immediate danger එකක් නැහැ but maintenance needed','දැනට issue එක minor','normal maintenance එකට schedule කරන්න පුළුවන්','small area එකක් විතරයි affected'],
   'Medium':['normal use එකට problem එකක් නිසා repair needed','issue එක continue වෙනවා soon check කරන්න','normally use කරන්න difficult','normal maintenance queue එකෙන් soon බලන්න','inconvenience එකක් තියෙනවා but immediate danger නැහැ'],
   'High':['issue එක quickly worse වෙනවා quick attention needed','large area එකකට or several residents affected වෙන්න පුළුවන්','delay වුණොත් more damage වෙන්න පුළුවන්','technician කෙනෙක් as soon as possible යොදවන්න','issue එක serious නිසා priority දෙන්න'],
   'Emergency':['residents හෝ property එකට immediate danger වෙන්න පුළුවන්','safety නිසා immediate attention needed','situation එක dangerous නිසා respond now','මේ safety issue එක delay කරන්න එපා','urgent help immediately needed']}
}


NATURAL_DETAIL = {
 'English':['It started this morning','It has happened more than once','The issue was noticed during normal use','The problem is inside the reported area','The condition has continued for some time','A resident noticed it recently','It is affecting normal apartment use','Please inspect the reported item','The problem is still present','The issue is easy to observe at the location'],
 'Singlish':['ada ude idan meka thiyenawa','meka kalinuth una','normal use karaddi meka notice una','report karapu area eke meka thiyenawa','tikak wela idan issue eka thiyenawa','resident kenek meka notice kala','normal apartment use ekata awul','report karapu item eka balanna','issue eka thama thiyenawa','location ekedi meka penenawa'],
 'Sinhala':['මේක අද උදේ සිට තියෙනවා','මේ ගැටලුව මීට පෙරත් වෙලා තියෙනවා','සාමාන්‍ය භාවිතයේදී මේක දැකගත්තා','වාර්තා කළ ප්‍රදේශයේ ගැටලුව තියෙනවා','ගැටලුව ටික වෙලාවක් තිස්සේ පවතිනවා','නේවාසිකයෙක් මේක මෑතකදී දැකගත්තා','සාමාන්‍ය අපාර්ට්මෙන්ට් භාවිතයට බාධාවක් තියෙනවා','වාර්තා කළ උපකරණය පරීක්ෂා කරන්න','ගැටලුව තවම පවතිනවා','ස්ථානයේදී ගැටලුව පැහැදිලිව පේනවා'],
 'Mixed':['මේක today morning ඉඳන් තියෙනවා','මේ issue එක beforeත් වෙලා තියෙනවා','normal use කරද්දී issue එක notice වුණා','reported area එකේ problem එක තියෙනවා','issue එක ටික වෙලාවක් continue වෙනවා','resident කෙනෙක් recently notice කළා','normal apartment use එකට problem එකක්','reported item එක please inspect කරන්න','issue එක still තියෙනවා','location එකේ problem එක clearly පේනවා'],
}

LANG_INDEX={'English':2,'Singlish':3,'Sinhala':4,'Mixed':5}

def row_for(category, scenario, language, i):
    priority,en,si,sn,mx,risk = scenario
    text=[en,si,sn,mx][LANG_INDEX[language]-2]
    prefix=random.choice(PREFIX[language])
    suffix=random.choice(SUFFIX[language])
    urgency=random.choice(PRIORITY_CONTEXT[language][priority])
    detail=random.choice(NATURAL_DETAIL[language])
    asset=random.choice(CAT[category][1])
    area=random.choice(CAT[category][2])
    # Text stays realistic. Uniqueness comes from natural combinations rather than artificial ID words.
    parts=[prefix,text,suffix,detail,urgency]
    random.shuffle(parts[2:])
    ticket_text='. '.join(parts) + '.'
    base={'Low':18,'Medium':42,'High':72,'Emergency':95}[priority]
    risk_score=max(0,min(100,base+random.randint(-5,5)))
    return {
      'ticket_text':ticket_text,'language_type':language,'building_block':random.choice(['Block A','Block B','Block C']),
      'floor':random.choice([0,1,2,3,5,8]),'area':area,'asset_type':asset,'category':category,'priority':priority,
      'technician_type':CAT[category][0],'safety_risk':risk,'response_time':{'Low':'Within 48 hours','Medium':'Within 24 hours','High':'Within 4 hours','Emergency':'Immediate'}[priority],
      'risk_score':risk_score,'duplicate_group':'','scenario_id':f"{category.lower().replace(' ','_')}_{risk.lower().replace(' ','_')}"
    }


def create_unique_rows(language, target_count, categories):
    rows=[]
    seen=set()
    attempts=0
    while len(rows) < target_count:
        attempts += 1
        if attempts > target_count * 80:
            raise RuntimeError(f'Could not create enough unique {language} rows.')
        category=categories[(len(rows)+attempts) % len(categories)]
        scenario=random.choice(SCENARIOS[category])
        row=row_for(category,scenario,language,attempts)
        key=row['ticket_text'].casefold()
        if key in seen:
            continue
        seen.add(key)
        rows.append(row)
    return rows


def main():
    DATA_DIR.mkdir(parents=True,exist_ok=True)
    languages=['English','Sinhala','Singlish','Mixed']
    per_language=TARGET_ROWS//4
    rows=[]
    categories=list(CAT)
    for lang in languages:
        rows.extend(create_unique_rows(lang, per_language, categories))
    random.shuffle(rows)
    fields=list(rows[0])
    with OUT.open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(rows)

    # Challenge records use the same category definitions but remove the repeated training wrappers.
    challenge=[]
    for category,scenarios in SCENARIOS.items():
        for sc in scenarios:
            priority,en,si,sn,mx,risk=sc
            texts={'English':en,'Singlish':si,'Sinhala':sn,'Mixed':mx}
            for lang in languages:
                asset=random.choice(CAT[category][1]); area=random.choice(CAT[category][2])
                base={'Low':18,'Medium':42,'High':72,'Emergency':95}[priority]
                challenge.append({
                    'ticket_text':texts[lang], 'language_type':lang, 'building_block':'Block A', 'floor':3,
                    'area':area, 'asset_type':asset, 'category':category, 'priority':priority,
                    'technician_type':CAT[category][0], 'safety_risk':risk,
                    'response_time':{'Low':'Within 48 hours','Medium':'Within 24 hours','High':'Within 4 hours','Emergency':'Immediate'}[priority],
                    'risk_score':base, 'duplicate_group':'',
                    'scenario_id':f"challenge_{category.lower().replace(' ','_')}_{risk.lower().replace(' ','_')}"
                })
    with CHALLENGE.open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(challenge)
    print(f'Created {len(rows):,} training rows and {len(challenge):,} challenge rows.')
    print(f'Scenario groups: {sum(len(v) for v in SCENARIOS.values())}.')

if __name__=='__main__': main()
