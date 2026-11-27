import Foundation

/// What ReccoBeats answered on 2026-11-27, asked only about public chart songs
/// (Shape of You, Blinding Lights, Mr. Brightside, and Nuvole Bianche for the
/// quiet neighbourhood). The JSON is as it arrived; the two tables are full
/// hundred-song answers cut down to the fields a mix reads, each joined with
/// the audio features asked for afterwards.
enum MixFixtures {
    /// GET /v1/track/recommendation?size=5&seeds=7qiZfU4dY1lWllzX7mPBI3,0VjIjW4GlUZAMYd2vXMi3b&valence=0.2&energy=0.3
    static let recommendation = Data(#"""
{"content":[{"id":"3256a844-bba0-4d3a-9c96-5ca4693ce39d","trackTitle":"0801","artists":[{"id":"8be1915b-6a3b-42fb-ae67-4c8da3b73991","name":"Stray Kids","href":"https://open.spotify.com/artist/2dIgFjalVxs4ThymZ67YCE"}],"durationMs":204026,"isrc":"US5TA2500186","ean":null,"upc":null,"href":"https://open.spotify.com/track/1IyV9GwfMVEVMymw8N4nsI","availableCountries":"AR,AU,AT,BE,BO,BR,BG,CA,CL,CO,CR,CY,CZ,DK,DO,DE,EC,EE,SV,FI,FR,GR,GT,HN,HK,HU,IS,IE,IT,LV,LT,LU,MY,MT,MX,NL,NZ,NI,NO,PA,PY,PE,PH,PL,PT,SG,SK,ES,SE,CH,TW,TR,UY,US,GB,AD,LI,MC,ID,TH,VN,RO,IL,ZA,SA,AE,BH,QA,OM,KW,EG,MA,DZ,TN,LB,JO,PS,IN,BY,KZ,MD,UA,AL,BA,HR,ME,MK,RS,SI,BD,PK,LK,GH,KE,NG,TZ,UG,AG,AM,BS,BB,BZ,BT,BW,BF,CV,CW,DM,FJ,GM,GE,GD,GW,GY,HT,JM,KI,LS,LR,MW,MV,ML,MH,FM,NA,NR,NE,PW,PG,PR,WS,SM,ST,SN,SC,SL,SB,KN,LC,VC,SR,TL,TO,TT,TV,VU,AZ,BN,BI,KH,CM,TD,KM,GQ,SZ,GA,GN,KG,LA,MO,MR,MN,NP,RW,TG,UZ,ZW,BJ,MG,MU,MZ,AO,CI,DJ,ZM,CD,CG,IQ,LY,TJ,VE,ET,XK","popularity":72},{"id":"389312cf-d75d-4314-8bf8-83f294be52f2","trackTitle":"two","artists":[{"id":"5ccebab1-ee7f-4576-bf7c-4522c1debc28","name":"bbno$","href":"https://open.spotify.com/artist/41X1TR6hrK8Q2ZCpp2EqCz"}],"durationMs":135212,"isrc":"QM24S2405396","ean":null,"upc":null,"href":"https://open.spotify.com/track/6DRZmJa38MaMNthwG3fCBD","availableCountries":"AR,AU,AT,BE,BO,BR,BG,CA,CL,CO,CR,CY,CZ,DK,DO,DE,EC,EE,SV,FI,FR,GR,GT,HN,HK,HU,IS,IE,IT,LV,LT,LU,MY,MT,MX,NL,NZ,NI,NO,PA,PY,PE,PH,PL,PT,SG,SK,ES,SE,CH,TW,TR,UY,US,GB,AD,LI,MC,ID,JP,TH,VN,RO,IL,ZA,SA,AE,BH,QA,OM,KW,EG,MA,DZ,TN,LB,JO,PS,IN,BY,KZ,MD,UA,AL,BA,HR,ME,MK,RS,SI,KR,BD,PK,LK,GH,KE,NG,TZ,UG,AG,AM,BS,BB,BZ,BT,BW,BF,CV,CW,DM,FJ,GM,GE,GD,GW,GY,HT,JM,KI,LS,LR,MW,MV,ML,MH,FM,NA,NR,NE,PW,PG,PR,WS,SM,ST,SN,SC,SL,SB,KN,LC,VC,SR,TL,TO,TT,TV,VU,AZ,BN,BI,KH,CM,TD,KM,GQ,SZ,GA,GN,KG,LA,MO,MR,MN,NP,RW,TG,UZ,ZW,BJ,MG,MU,MZ,AO,CI,DJ,ZM,CD,CG,IQ,LY,TJ,VE,ET,XK","popularity":83},{"id":"6ff01886-59ec-43f9-9f95-48de02798fb0","trackTitle":"Shut Up and Dance","artists":[{"id":"8392816a-6e11-48b1-97f8-2dda452d735a","name":"WALK THE MOON","href":"https://open.spotify.com/artist/6DIS6PRrLS3wbnZsf7vYic"}],"durationMs":199080,"isrc":"USRC11401949","ean":null,"upc":null,"href":"https://open.spotify.com/track/4kbj5MwxO1bq9wjT5g9HaA","availableCountries":"AR,AU,AT,BE,BO,BR,BG,CA,CL,CO,CR,CY,CZ,DK,DO,DE,EC,EE,SV,FI,FR,GR,GT,HN,HK,HU,IS,IE,IT,LV,LT,LU,MY,MT,MX,NL,NZ,NI,NO,PA,PY,PE,PH,PL,PT,SG,SK,ES,SE,CH,TW,TR,UY,US,GB,AD,LI,MC,ID,JP,TH,VN,RO,IL,ZA,SA,AE,BH,QA,OM,KW,EG,MA,DZ,TN,LB,JO,PS,IN,BY,KZ,MD,UA,AL,BA,HR,ME,MK,RS,SI,KR,BD,PK,LK,GH,KE,NG,TZ,UG,AG,AM,BS,BB,BZ,BT,BW,BF,CV,CW,DM,FJ,GM,GE,GD,GW,GY,HT,JM,KI,LS,LR,MW,MV,ML,MH,FM,NA,NR,NE,PW,PG,PR,WS,SM,ST,SN,SC,SL,SB,KN,LC,VC,SR,TL,TO,TT,TV,VU,AZ,BN,BI,KH,CM,TD,KM,GQ,SZ,GA,GN,KG,LA,MO,MR,MN,NP,RW,TG,UZ,ZW,BJ,MG,MU,MZ,AO,CI,DJ,ZM,CD,CG,IQ,LY,TJ,VE,ET,XK","popularity":83},{"id":"e56c9b06-d5f3-40e7-8b5a-d9353e940d19","trackTitle":"ATTITUDE","artists":[{"id":"d0c0036f-e58b-47cf-8795-14a27a17066d","name":"IVE","href":"https://open.spotify.com/artist/6RHTUrRF63xao58xh9FXYJ"}],"durationMs":194733,"isrc":"QMFMF2434281","ean":null,"upc":null,"href":"https://open.spotify.com/track/49oOgXKqm6xTavBtekzVHg","availableCountries":"AR,AU,AT,BE,BO,BR,BG,CA,CL,CO,CR,CY,CZ,DK,DO,DE,EC,EE,SV,FI,FR,GR,GT,HN,HK,HU,IS,IE,IT,LV,LT,LU,MY,MT,MX,NL,NZ,NI,NO,PA,PY,PE,PH,PL,PT,SG,SK,ES,SE,CH,TW,TR,UY,US,GB,AD,LI,MC,ID,TH,VN,RO,IL,ZA,SA,AE,BH,QA,OM,KW,EG,MA,DZ,TN,LB,JO,PS,IN,BY,KZ,MD,UA,AL,BA,HR,ME,MK,RS,SI,BD,PK,LK,GH,KE,NG,TZ,UG,AG,AM,BS,BB,BZ,BT,BW,BF,CV,CW,DM,FJ,GM,GE,GD,GW,GY,HT,JM,KI,LS,LR,MW,MV,ML,MH,FM,NA,NR,NE,PW,PG,PR,WS,SM,ST,SN,SC,SL,SB,KN,LC,VC,SR,TL,TO,TT,TV,VU,AZ,BN,BI,KH,CM,TD,KM,GQ,SZ,GA,GN,KG,LA,MO,MR,MN,NP,RW,TG,UZ,ZW,BJ,MG,MU,MZ,AO,CI,DJ,ZM,CD,CG,IQ,LY,TJ,VE,ET,XK","popularity":76},{"id":"e84f114b-d0c2-4b73-aa54-460c6e9a0629","trackTitle":"Save Your Tears (with Ariana Grande) (Remix)","artists":[{"id":"9451b6b2-8746-4d43-abd7-c355ed1e3048","name":"The Weeknd","href":"https://open.spotify.com/artist/1Xyo4u8uXC1ZmMpatF05PJ"},{"id":"320a87e6-a2b9-421f-9b4e-aa44f8c784bb","name":"Ariana Grande","href":"https://open.spotify.com/artist/66CXWjxzNUsdJxJ2JdwvnR"}],"durationMs":191013,"isrc":"USUG12101839","ean":null,"upc":null,"href":"https://open.spotify.com/track/37BZB0z9T8Xu7U3e65qxFy","availableCountries":"AR,AU,AT,BE,BO,BR,BG,CA,CL,CO,CR,CY,CZ,DK,DO,DE,EC,EE,SV,FI,FR,GR,GT,HN,HK,HU,IS,IE,IT,LV,LT,LU,MY,MT,MX,NL,NZ,NI,NO,PA,PY,PE,PH,PL,PT,SG,SK,ES,SE,CH,TW,TR,UY,US,GB,AD,LI,MC,ID,JP,TH,VN,RO,IL,ZA,SA,AE,BH,QA,OM,KW,EG,MA,DZ,TN,LB,JO,PS,IN,BY,KZ,MD,UA,AL,BA,HR,ME,MK,RS,SI,KR,BD,PK,LK,GH,KE,NG,TZ,UG,AG,AM,BS,BB,BZ,BT,BW,BF,CV,CW,DM,FJ,GM,GE,GD,GW,GY,HT,JM,KI,LS,LR,MW,MV,ML,MH,FM,NA,NR,NE,PW,PG,WS,SM,ST,SN,SC,SL,SB,KN,LC,VC,SR,TL,TO,TT,TV,VU,AZ,BN,BI,KH,CM,TD,KM,GQ,SZ,GA,GN,KG,LA,MO,MR,MN,NP,RW,TG,UZ,ZW,BJ,MG,MU,MZ,AO,CI,DJ,ZM,CD,CG,IQ,LY,TJ,VE,ET,XK","popularity":76}]}
"""#.utf8)

    /// GET /v1/audio-features?ids=7qiZfU4dY1lWllzX7mPBI3,0VjIjW4GlUZAMYd2vXMi3b,3n3Ppam7vgaVa1iaRUc9Lp,0000000000000000000000
    /// The fourth ID doesn't exist and is simply missing.
    static let features = Data(#"""
{"content":[{"id":"636463ea-c943-44d5-b600-1fa6f3ad8057","href":"https://open.spotify.com/track/3n3Ppam7vgaVa1iaRUc9Lp","isrc":"GBFFP0300052","acousticness":0.00119,"danceability":0.355,"energy":0.918,"instrumentalness":0.0,"key":1,"liveness":0.0971,"loudness":-4.36,"mode":1,"speechiness":0.0746,"tempo":148.114,"valence":0.24},{"id":"25c8ca63-5895-4572-84eb-a7040bc08c4d","href":"https://open.spotify.com/track/0VjIjW4GlUZAMYd2vXMi3b","isrc":"USUG11904206","acousticness":0.00143,"danceability":0.513,"energy":0.73,"instrumentalness":9.54E-5,"key":1,"liveness":0.0897,"loudness":-5.94,"mode":1,"speechiness":0.0598,"tempo":171.001,"valence":0.334},{"id":"ef0e9524-99b3-483c-9690-6abd71e6064d","href":"https://open.spotify.com/track/7qiZfU4dY1lWllzX7mPBI3","isrc":"GBAHS1600463","acousticness":0.581,"danceability":0.825,"energy":0.652,"instrumentalness":0.0,"key":1,"liveness":0.0931,"loudness":-3.183,"mode":0,"speechiness":0.0802,"tempo":95.977,"valence":0.931}]}
"""#.utf8)

    /// HTTP 400 for seeds=0000000000000000000000,1111111111111111111111
    static let unknownSeeds = Data(#"""
{"timestamp":"2026-11-27T07:54:48.142+00:00","error":"Cannot find any track for given seed ids, seeds need at least one track","path":"uri=/v1/track/recommendation","status":4002}
"""#.utf8)

    /// HTTP 400 for six seeds.
    static let tooManySeeds = Data(#"""
{"status":4004,"errors":[{"path":"getRecommendation.seeds","message":"size must be between 1 and 5"}]}
"""#.utf8)

    /// HTTP 400 for size=101.
    static let sizeTooLarge = Data(#"""
{"status":4004,"errors":[{"path":"getRecommendation.size","message":"must be less than or equal to 100"}]}
"""#.utf8)

    /// HTTP 200 for audio features of IDs it doesn't know.
    static let nothing = Data(#"{"content":[]}"#.utf8)

    typealias Row = (id: String, title: String, artists: [String], durationMs: Int, valence: Double, energy: Double)

    /// The 88 songs answered for the three pop seeds: loud and mostly cheerful
    /// (median valence 0.55, energy 0.80; two songs under 0.5 energy).
    static let pop: [Row] = [
        ("4NSW0Km5ZG60L8FthUebPJ", "What I Like About You (feat. Theresa Rex)", ["Jonas Blue", "Theresa Rex"], 220396, 0.553, 0.800),
        ("6qJjgYxhZ3gBTm4TI8t41e", "FISH N STEAK (WHAT IT IS) (feat. Tyler, The Creator & Jozzy)", ["A$AP Rocky", "Tyler, The Creator", "Jozzy"], 229102, 0.538, 0.734),
        ("4UANYptjv2kpV6IY7IjXoJ", "Bem Pior Que Eu - Ao Vivo", ["Marília Mendonça"], 168172, 0.404, 0.652),
        ("0A9FAzeaUEMHB68FPk3GYc", "CUORICINI", ["Coma_Cose"], 194090, 0.605, 0.807),
        ("7iee007QypdrTXbLVF5KuF", "Love Generation - Edit", ["Bob Sinclar", "Gary Pine", "Goleo VI"], 204105, 0.553, 0.856),
        ("664gdARxaClFsoF5SXKOws", "Here", ["Alessia Cara"], 199453, 0.327, 0.822),
        ("2otAnGaeFFFeIDV8nbu5uA", "el cielo", ["TINI"], 188671, 0.581, 0.869),
        ("6AX3i1TluzbvpJpKrY7NoD", "SWEET SPOT", ["Justin Bieber", "Sexyy Red"], 185213, 0.822, 0.712),
        ("1kFevEv3s7Gf6o5xSDR5DL", "LOVE ME RIGHT", ["EXO"], 205128, 0.757, 0.830),
        ("5hKjEpYrJIJs6uPl7zw6Y6", "No Te Hagas", ["Jory Boy", "Bad Bunny"], 233250, 0.433, 0.690),
        ("66SvxvblhUIEL6awyLMGL2", "El Circo", ["El Fantasma"], 137323, 0.772, 0.533),
        ("11lw4bWbmxWIETHitBU0Gc", "Blood on the Dance Floor", ["Michael Jackson"], 253000, 0.558, 0.741),
        ("0gCPvo1GkbtPhMqg5Gbx1K", "Vuelve", ["Daddy Yankee", "Bad Bunny"], 279613, 0.199, 0.531),
        ("61FfbHfk4qT8ZzNA5dqN9j", "Finesse Out The Gang Way (feat. Lil Baby)", ["Lil Durk", "Lil Baby"], 186283, 0.495, 0.887),
        ("4VWey6HeiWBss4b0vVQ6IA", "That Summer", ["NCT DREAM"], 198013, 0.622, 0.934),
        ("1jFcVCd4gKDiwmj7JsD8Jd", "Sossaup", ["KAYTRAMINÉ", "Aminé", "KAYTRANADA"], 156000, 0.276, 0.826),
        ("6pVW5LRWgeLaHudxauOTJU", "Jingle Bell Rock - Daryl's Version", ["Daryl Hall & John Oates", "SMLA", "Daryl Hall"], 126360, 0.840, 0.841),
        ("2DmALIEmzfK4QDi6yg26Hh", "Ohnana (feat. Farruko & Nicky Jam) - Remix", ["Kapo", "Maluma", "Ryan Castro"], 317714, 0.492, 0.871),
        ("0pcU4T0Gz8XUobyjdoWb6f", "Everyone’s A Star!", ["5 Seconds of Summer"], 195229, 0.421, 0.914),
        ("4NoQsZ4o0IGZTZt4QFFlZa", "Start", ["The Neighbourhood"], 159266, 0.425, 0.877),
        ("66tlRqExpkn4kRyuxelzs5", "ANYTHING BUT LOVE", ["Tate McRae"], 147293, 0.525, 0.728),
        ("7abZdMxSDfDDf7HKB8Ae8r", "SMOKE THE PAIN AWAY", ["Calvin Harris"], 162772, 0.423, 0.924),
        ("161DnLWsx1i3u1JT05lzqU", "Talking to the Moon", ["Bruno Mars"], 217866, 0.078, 0.590),
        ("252UPuQsncbBFhTrx4Ytcc", "La Diabla", ["Romeo Santos"], 239026, 0.882, 0.747),
        ("6b6KXDbDn0s0Jepxm8a3nr", "FOREVER", ["BABYMONSTER"], 212734, 0.661, 0.703),
        ("3z6s6qPDYCpW44Zfpy4HWS", "Afuera Está Lloviendo", ["Julión Álvarez y su Norteño Banda"], 179106, 0.615, 0.499),
        ("6GBKwWdmHaTqbguQgAYOIz", "The Horse and the Infant", ["Jorge Rivera-Herrans", "Luke Holt", "Cast of EPIC: The Musical"], 234000, 0.268, 0.745),
        ("2mYlSgPvC5Np4mDg9DU5Mc", "CARITA TRISTE", ["Ana Mena", "Emilia"], 175296, 0.614, 0.793),
        ("0xwkZlqjlnG8nfv8JK4xFI", "33", ["Ho3ein", "Epicure"], 236846, 0.504, 0.842),
        ("0FGJCIfldAfhKfeispTyL5", "Decades", ["Motionless In White"], 231617, 0.274, 0.989),
        ("3AjfuVk6olyesS7cVfofBE", "HOT SAUCE", ["BABYMONSTER"], 147807, 0.811, 0.860),
        ("7ytAHohytO1TxO9yF5vn7d", "SOLTERO", ["elaggume", "ECKO", "Omar Varela"], 145823, 0.752, 0.699),
        ("1OH0dxRdfoKbZG9ubxiT7I", "Summer Baby", ["Azet", "The Underdog Project"], 143276, 0.341, 0.763),
        ("2QrGCbW0ylj94JfkgLZFlA", "Pa Ti", ["Bad Bunny", "Bryant Myers"], 191294, 0.557, 0.718),
        ("1Bqg4yFeVDJxchh6MjkGKy", "Chambea", ["Bad Bunny"], 192001, 0.638, 0.866),
        ("6g95dK7o7vVh8ZCnDAseU5", "كلام عينيه", ["Sherine"], 235833, 0.745, 0.759),
        ("3GiORO0zRwRT3g9CCklzkQ", "It's That Time - FISHER Remix", ["Marlon Hoffstadt", "FISHER"], 171717, 0.936, 0.978),
        ("5CtXR89REICvEZljUEK8r1", "Do Jeito Que Você Mete", ["DJ L30", "MC Thaizinha"], 120950, 0.738, 0.459),
        ("5Fhr3wqeieN5WDkAsqL1JJ", "MONA LISA", ["j-hope"], 137191, 0.960, 0.805),
        ("2vzpoecVhBE1pKtHzKONaN", "Seluruh Nafas Ini", ["Last Child", "Gisel"], 292337, 0.267, 0.526),
        ("1S9fKs0sAdZPlL8ViOARnS", "João 20 + pra Sempre - Ao Vivo", ["Vitor Santana"], 289313, 0.384, 0.709),
        ("1auxYwYrFRqZP7t3s7w4um", "Ni**as In Paris", ["JAY-Z", "Kanye West"], 219333, 0.775, 0.858),
        ("7ePFgZKyrd38XLTOasoEjk", "Say", ["UZI", "FT Kings"], 144079, 0.589, 0.780),
        ("6IBPrw5nYj84x8JpiOvXUp", "You(=I)", ["BOL4"], 169477, 0.681, 0.895),
        ("5Vuq8CP31cpEEq5zNJCjUN", "JOGO DE TOLOS", ["Scythermane", "luc wall", "Lurk"], 70400, 0.384, 0.920),
        ("4utjEtHZpJmCqdD9KtpBJi", "Wenn du mich siehst", ["Samra"], 161237, 0.545, 0.793),
        ("52NGJPcLUzQq5w7uv4e5gf", "Private Landing (feat. Justin Bieber & Future)", ["Don Toliver", "Justin Bieber", "Future"], 238253, 0.445, 0.641),
        ("4vyQ2NdodXhtMGsaaMBqSt", "M.I.A", ["KATSEYE"], 129683, 0.669, 0.893),
        ("5FZxsHWIvUsmSK1IAvm2pp", "Best of You", ["Foo Fighters"], 255626, 0.369, 0.940),
        ("5IShqQgFFTRRpQVVubD52f", "Te quiero", ["Hombres G", "Carin Leon"], 214781, 0.642, 0.568),
        ("3TgMcrV32NUKjEG2ujn9eh", "It's Not Living (If It's Not With You)", ["The 1975"], 248335, 0.526, 0.837),
        ("5yvhdo8FXbBsIllxv2Rr94", "Prom", ["SZA"], 196133, 0.225, 0.702),
        ("1NFCHmE6p7icHYwr5QQal2", "Stop", ["Canserbero", "Apache", "Cancerbero"], 310093, 0.780, 0.899),
        ("1tfZtA15BfJHQTUy3dqTKC", "Build Me Up Buttercup - Mono", ["The Foundations", "Foundations"], 180133, 0.879, 0.664),
        ("6WVUCSF2fDkuvvCRk7VFkF", "I Hate That It's True", ["Dean Lewis"], 161420, 0.354, 0.740),
        ("4lUAlhQOVzhitQKjxrHVny", "SHYNE", ["Travis Scott", "GloRilla"], 193183, 0.474, 0.770),
        ("7g0VHb0AYPsMqjX1x3eDOU", "Saree (From \"Dhamaal 4\")", ["Tanishk Bagchi", "Sanju Rathod", "G-SPXRK"], 236036, 0.896, 0.852),
        ("0qlu7Te2J2BuAGFcwb3rjn", "FUN", ["Rema"], 188981, 0.396, 0.838),
        ("2CANOkgHGULkQ4ldm9xx5D", "For Once in My Life", ["Kylie Cantrall", "Alexandro Byrd", "Descendants – Cast"], 182309, 0.683, 0.789),
        ("5lwPKH5nmro0uXGs8PiAQq", "TENGO CELOS", ["Myke Towers"], 211101, 0.808, 0.803),
        ("2Om8fOpJjFtSn7MGdj3aen", "Dillo Solo Al Buio", ["Elisa"], 225365, 0.397, 0.708),
        ("1z9adRe4kaugMq3E8HX3c6", "MANESKIN (feat. Ghali, Shiva)", ["Sadturs", "KIID", "Ghali"], 148346, 0.346, 0.639),
        ("3zEtrCrypOOIWKEapaTpq5", "Think About Us", ["Sonny Fodera", "D.O.D", "Poppy Baskcomb"], 178148, 0.491, 0.559),
        ("0fLOPPoyIaPTe8dm2Mrft3", "Tú No Lo Amas", ["Anuel AA", "Emy Music"], 214125, 0.389, 0.733),
        ("19eIZmuXlBmLTha1lPHef7", "Alors On Danse - DubDogz Remix", ["Stromae", "Dubdogz"], 168576, 0.739, 0.752),
        ("3YVPpVJvJG2EauXurPA90F", "Tell It to My Heart", ["Taylor Dayne"], 220880, 0.723, 0.988),
        ("65n40RsQ9SObH7hNvVTHp0", "Explícale (feat. Cosculluela & Brytiago) - Remix", ["Yandel", "Bad Bunny", "Noriel"], 395666, 0.587, 0.682),
        ("5Aw7IBvOzLPqlJRPCqnTkL", "Nem a Pau (feat. Simone Mendes) - Ao Vivo", ["Yasmin Santos", "Simone Mendes"], 161920, 0.554, 0.794),
        ("7gdAgbYxtwwXsWsItU1apk", "Lucky", ["Halsey"], 198546, 0.728, 0.650),
        ("7yH9SbrDQfNIh89ACCR7Ib", "King", ["TWOPILOTS"], 210000, 0.396, 0.862),
        ("5uB6EOgFVsglkVJAUZe0r2", "El Compa Icta", ["Grupo Maximo Grado", "Luis R Conriquez"], 175762, 0.947, 0.904),
        ("2t1pEpxPz91KldW7C0FyZv", "Monica (From \"Coolie\") (Tamil)", ["Anirudh Ravichander", "Sublahshini", "Asal Kolaar"], 217627, 0.608, 0.765),
        ("4OssqCixV2Xsxd43wMIQyS", "CARNIVAL", ["Kanye West", "Ty Dolla $ign", "¥$"], 264324, 0.311, 0.811),
        ("63jUTfcbudnrqoPCC5Qp4i", "SEXXXMACHINE", ["Rauw Alejandro"], 236352, 0.649, 0.826),
        ("5aJkU10zRAGppI7YxDZR0l", "Marca Mandarina - Prod. by Ernesto Losa", ["Bebeshito", "El Taiger", "Ernesto Losa"], 193288, 0.613, 0.879),
        ("13Z2JpNwN54a5WXacGYtLs", "Made It On Our Own", ["Yeat", "EsDeeKid"], 169090, 0.387, 0.791),
        ("1kmeChA8VINeDprVkTHRhW", "Protagonista", ["LIT killah", "Paulo Londra", "Big One"], 159272, 0.334, 0.759),
        ("23W44WWCP8SibyP292TWo5", "JACKPOT", ["Belinda", "Kenia OS"], 193360, 0.594, 0.806),
        ("1S1WSh4uCprvucg6Hx57Eh", "ブルーアンビエンス", ["Mrs. GREEN APPLE", "asmi"], 250773, 0.730, 0.906),
        ("0ITaSRuI0L1RNL7ZNYTTi7", "U Are My High (with Future)", ["DJ Snake", "Future"], 211200, 0.442, 0.824),
        ("7bO7a1KrtmGNDIOy2u3siZ", "FOMDJ", ["Playboi Carti"], 200253, 0.077, 0.795),
        ("18e3XXYCv4Tx8uUl1mP3CN", "Balam Pichkari", ["Pritam", "Vishal Dadlani", "Shalmali Kholgade"], 288902, 0.957, 0.944),
        ("6YiIWuVXS4AqF1KvUGMwyx", "crystallized (feat. Inéz)", ["John Summit", "Inéz"], 217646, 0.292, 0.857),
        ("2OKo7g3KfmCt3kyLvUAL0g", "The Search", ["NF"], 248040, 0.390, 0.786),
        ("1qmgaJLG35mtGR4tSIfFjb", "I Don't Like You Anymore", ["Maddox Batson"], 155133, 0.612, 0.673),
        ("1W3ohWNGNobBwSrOuVSxel", "Na Hora Da Raiva - Ao Vivo", ["Henrique & Juliano"], 174117, 0.480, 0.874),
        ("5yb3mQBiZomUePinuVmr1Y", "La Batidora - Prod. by Ernesto Losa", ["Bebeshito", "Ernesto Losa"], 178492, 0.653, 0.854),
        ("12QsAlRWEyg3AB7qqPSJ4s", "Hundred Mile High", ["Cameron Whitcomb"], 172181, 0.566, 0.803),
    ]

    /// The 93 songs answered for one quiet piano seed (median valence 0.16, energy 0.20).
    static let calm: [Row] = [
        ("5k5Hp2PiUhNV7LslFlJq69", "Hebel", ["Jacob LaVallee"], 152124, 0.070, 0.085),
        ("157YsVQ3ijH1S5wTAK43Hi", "Limitations", ["East Forest"], 255626, 0.062, 0.189),
        ("2dgqNkXGpJBIsAw5hzcIbq", "Sleepveil (with rain)", ["Sleepyhead"], 150083, 0.039, 0.175),
        ("16KZuJfRKqMZQvmOibsVqX", "Solar - Rudy Van Gelder Remaster", ["Miles Davis Quintet"], 282866, 0.697, 0.181),
        ("3GLF4uV3uS1ImSEPyhLZLp", "Yebo", ["TxC", "Davido", "Tony Duardo"], 263683, 0.370, 0.260),
        ("4Zs5DSz0nNvKWMTNKoAQ78", "Meets the Sea", ["Nordklang Collective"], 217121, 0.052, 0.086),
        ("1LcNtS9B22LgIHxd9gTGcV", "Main Titles (From the HBO Miniseries \"Band of Brothers\" Soundtrack)", ["London Metropolitan Orchestra", "Michael Kamen", "Maire Brennan"], 144893, 0.039, 0.176),
        ("6IFvJNL14GWccdz1wwamBO", "Rachel's Theme", ["Anne Dudley"], 88506, 0.076, 0.169),
        ("2zCkNzlHo5e0kFTfrUjTkt", "Maantje tuurt", ["Juf Roos"], 78000, 0.815, 0.075),
        ("1hWAwQdCbDkEF6hoLRU7ic", "Rain Sounds for Sleeping, Pt. 45 (Continuous No Gaps)", ["White Noise Radiance", "Rain Sounds"], 360000, 0.000, 0.998),
        ("6zFsz86nAj5gcvzyVqNL3k", "I Fall To Pieces - Single Version", ["Patsy Cline", "The Jordanaires", "Jim Reeves"], 171333, 0.506, 0.057),
        ("0bSP50zA33XVCgA3vESOQo", "A BEAST WITH BEAUTY", ["millkzy"], 173877, 0.240, 0.232),
        ("4un7tX9V9E4O06ogDdtSpv", "Mi Arbol Y Yo", ["Alberto Cortez"], 213446, 0.411, 0.245),
        ("4uHi4vmmMV5tN1tENULUEt", "Fast Jazz Dance", ["Cafe Music BGM channel"], 165511, 0.431, 0.336),
        ("6E59ljVX0peiUOd3yvNAxC", "Back To The Rivers Of Belief: Way To Eternity / Hallelujah / The Rivers Of Belief", ["Enigma"], 636266, 0.207, 0.356),
        ("17BbOUg4bw1howTr10lf8v", "Wie viele Tränen", ["CedMusic", "Zate", "Rewindbeats"], 142195, 0.491, 0.373),
        ("1ky5wGKiUmUAxqLxWnIaQI", "Stars", ["‍ Nagi"], 140727, 0.083, 0.555),
        ("4UpoLlvx8WWpygrLr0OsOd", "Moon 2", ["Men I Trust"], 176844, 0.094, 0.169),
        ("6qMwBXtzsJSIjvcvU4XM4h", "I Want to Fall in Love Again", ["Jonah Anderson"], 232500, 0.212, 0.166),
        ("68F60nXjq5ahxsVPSmCvq1", "La Llorona", ["Chavela Vargas"], 327893, 0.441, 0.108),
        ("204dYDNObhQPnlz0ujMcjg", "Sparkle Song", ["Florist"], 206318, 0.397, 0.123),
        ("5plmIyPZMZWUlwbmgyty7J", "Returning the Crown", ["Marc Streitenfeld"], 73733, 0.169, 0.527),
        ("0aLgCWazFYVuABVvvkUOyg", "Coventry Carol", ["The City of Prague Philharmonic Orchestra", "Crouch End Festival Chorus"], 205626, 0.043, 0.150),
        ("2UnqYqJgyjElVUmX87rbrW", "Ill Wind", ["Will Mays"], 151110, 0.106, 0.138),
        ("1vTbZnionnHB5KgxOcTcpD", "Have Yourself A Merry Little Christmas", ["Frank Sinatra"], 236733, 0.195, 0.171),
        ("5K9DCY2iSG4JkY0hZpd2X2", "سورة النبأ كاملة", ["عبدالرحمن مسعد"], 337441, 0.396, 0.120),
        ("44g7pyfENFL4U0l4V9Mf7A", "Stand with Maui", ["Hans Zimmer", "James Everingham", "Kaumakaiwa Kanaka'ole"], 165813, 0.034, 0.167),
        ("5ATiP9nXYyxshwrkuyM3HK", "Just For You", ["Fröe"], 124413, 0.431, 0.071),
        ("3fbxw3kKc1DXur3hxgTdXA", "Entrance", ["Loathe", "bucki sugar"], 121306, 0.040, 0.302),
        ("6vB0Ifi9fP9Tk5EChw91Hi", "Abzugshaube (Sanft)", ["Baby Sleep Baby Sounds"], 210835, 0.028, 0.163),
        ("45VBKPvK3eri0lPl1VKdFH", "Rain Sounds for Sleeping, Pt. 26 (Continuous No Gaps)", ["White Noise Radiance", "Rain Sounds"], 360000, 0.000, 0.998),
        ("68ugUmH1wjIN0vCR98sC7G", "Once in Royal David's City", ["Red Brick Lane"], 165225, 0.319, 0.098),
        ("01OXa5tVuCssU6j8TY7kxr", "Words", ["Low"], 348800, 0.229, 0.209),
        ("3rpBkWpINIPd8F4m3u1BCx", "Emmanuel", ["Hillside Recording", "Diana Trout"], 239268, 0.184, 0.185),
        ("0nJgsQqeqEU6nYipv81Ttw", "Peaceful evenings", ["Maria Isabel Ferrer"], 136670, 0.342, 0.113),
        ("1PWaRr1hfcJsfRBArMm5CF", "Kapitel 14: Die Fohlenfreundschaft (Folge 119)", ["Bibi und Tina"], 185884, 0.625, 0.287),
        ("1dZCiUTIbbvwOCALmzBh9y", "Oogway Ascends", ["Hans Zimmer", "John Powell"], 123506, 0.079, 0.235),
        ("3ayvi21PAEf43yKuS0Mvb7", "My Darling", ["Ikigai"], 225454, 0.104, 0.249),
        ("2YLsKOCAC9mpnmXGtb8Eev", "Lunar", ["Mac Kay"], 136848, 0.248, 0.246),
        ("0Z94dtWElamDwU4NrcGoUR", "Better", ["sign crushes motorist"], 98750, 0.349, 0.087),
        ("3ogD7RDBiQ3SccBVO0uq3B", "Rain Sounds for Sleeping, Pt. 19 (Continuous No Gaps)", ["White Noise Radiance", "Rain Sounds"], 360000, 0.000, 0.998),
        ("7ajlrB8oseDm5dhAaJiCnh", "While Shepherds Watched Their Flocks (Desc. by Stephen Cleobury)", ["Este's Psalter, 1592", "Choir of King's College, Cambridge", "Stephen Cleobury"], 164346, 0.169, 0.182),
        ("4hjtTg7x0FqTXGnSCZn4wo", "Clearly", ["Hillside Recording"], 223486, 0.170, 0.255),
        ("74krwfjFtta8JC9d5W7rFT", "Rain Sounds for Sleeping, Pt. 37 (Continuous No Gaps)", ["White Noise Radiance", "Rain Sounds"], 360000, 0.000, 0.998),
        ("08w84SD08M8bE1beK2mG1P", "Forte pluie et tonnerre", ["Orage et pluit"], 146333, 0.021, 0.943),
        ("6C0X99BDhZzm0o4gx9arqm", "UNDERSTAND", ["keshi"], 150519, 0.163, 0.208),
        ("6cbiH9ayUzdB3AZsO9GdNs", "Eternity Present", ["Rand Aldo"], 150106, 0.354, 0.176),
        ("2Hhngl3KwlefHtY0hORMH4", "Away in a Manger", ["William J. Kirkpatrick", "Boulanger Trio", "Asya Fateyeva"], 197165, 0.117, 0.136),
        ("0ZuRO5TjEcp9xmyLlZiIJA", "How Deep is Your Love", ["Kiris Houston"], 226433, 0.132, 0.223),
        ("77whg2lFFeoZd9TVvR7Tu1", "Rain Sounds for Sleeping, Pt. 30 (Continuous No Gaps)", ["White Noise Radiance", "Rain Sounds"], 360000, 0.000, 0.998),
        ("7gbSDq9luQx6yVl7HyJGIW", "Dismantle", ["Peter Sandberg"], 115578, 0.396, 0.136),
        ("7tA2yJHI46hAbu4rGU5fmD", "Passacaglia (Piano Version)", ["Pianovus"], 155000, 0.242, 0.168),
        ("713uZZEPsZpm5NxzUfCJ71", "Enamorado", ["emmanuellcortess_"], 188637, 0.228, 0.202),
        ("3nSTb8hxLHbDdG8oEXYy5u", "Nothing Like a Spring", ["Trio Del Norte"], 211757, 0.244, 0.238),
        ("2Ybr5CJgausQTZGIIpB1JS", "Thy Word - Piano and Orchestra Version", ["Praise and Worship Orchestra"], 203040, 0.154, 0.076),
        ("6yfollCsqwuGFZJWpYPpTL", "Kapitel 32: Toteninsel", ["Die drei ???"], 185271, 0.608, 0.478),
        ("1dY7dxmqRH6ZslllYvQMjW", "La Explicación", ["Kidd Voodoo"], 118874, 0.694, 0.196),
        ("6e5NXvhtb7cEaNWUXZvIWZ", "Wouldn't It Be Nice", ["The Poet"], 140838, 0.305, 0.083),
        ("6xMatwWPx2Xot79SDL3oIH", "Papillon", ["Secret Garden", "Rolf Løvland"], 206133, 0.128, 0.198),
        ("7D6AsBsqCat5Szh584k1d8", "His Name Is Wonderful", ["I Love You Lord Performers"], 134026, 0.280, 0.265),
        ("10c2cDnd14oZQiMQsUksDd", "Idea 7 (Sped Up)", ["Gibran Alcocer"], 115415, 0.501, 0.162),
        ("6gtBBy7CCIkW8PGCZQNAsQ", "Rain Sounds for Sleeping, Pt. 78 (Continuous No Gaps)", ["White Noise Radiance", "Rain Sounds"], 360000, 0.000, 0.998),
        ("6HcSIn5EsFz20aillG9Itv", "Maine", ["Oscar Roland"], 164052, 0.170, 0.076),
        ("5R4nEl8XfFBPS2kxk5KOgi", "if you do", ["loutwo"], 150706, 0.111, 0.123),
        ("4pqukGPXdo8FC84JDIapTH", "Rain Sounds for Sleeping, Pt. 36 (Continuous No Gaps)", ["White Noise Radiance", "Rain Sounds"], 360000, 0.000, 0.998),
        ("2aYDkRXpyPpNrAuui8GNQJ", "Rain Sounds for Sleeping, Pt. 60 (Continuous No Gaps)", ["White Noise Radiance", "Rain Sounds"], 360000, 0.000, 0.998),
        ("4rdZ88Td74DhfT67dSLkmd", "Le Nozze Di Figaro K.492, IWM 348", ["Wolfgang Amadeus Mozart", "Moony's Music Box"], 92779, 0.953, 0.181),
        ("3EEerX6cdmRrNq1jTzSWah", "Thunder Afternoon (Rain)", ["Natsound"], 184000, 0.013, 0.995),
        ("0aDEoQUavE0KcogkeBPd27", "Tales and Legends", ["Fantasy Village"], 73496, 0.069, 0.118),
        ("4zS1GqwMvfSsA0g48qvxAq", "Roja - Version, 1", ["A.R. Rahman", "S. P. Balasubrahmanyam", "K. S. Chithra"], 306146, 0.431, 0.319),
        ("6BNaBJvHM85qDtsw9pUCD0", "Me Voy Contigo", ["Los Aptos", "DannyLux"], 222191, 0.438, 0.201),
        ("2rmSKWVQ6c8jtRjftLJG5c", "Locksmith", ["Chanin"], 173548, 0.484, 0.233),
        ("00HHooJvGlZDuDx98B66Sx", "Nick & Noah", ["Jakwob", "James Jacob"], 83080, 0.047, 0.279),
        ("5ssWk7MoYjKM9ThGXTNcei", "The New Order", ["Mick Gordon"], 223889, 0.096, 0.245),
        ("4PFhHd7DsNg0ke9Nmlxms5", "Blue Eyes - Remastered 2003", ["Elton John"], 206266, 0.159, 0.229),
        ("62LIjQ7uet2hOT9577QYoq", "Affection", ["Hunter Paige"], 206993, 0.060, 0.165),
        ("1kRFLxLcYCr8NxyfQmLfjq", "Our Love", ["Moonlight Echoes"], 63261, 0.072, 0.040),
        ("7hZaDigMQ2rCsXJ1dk4Zwv", "New Magic Wand", ["Jaegershu"], 66430, 0.513, 0.434),
        ("5oDDDUE5p4It0FvKVveFWr", "Annas Visa", ["Alec Taylor Trio"], 193367, 0.086, 0.179),
        ("5KIOfWtUEKrxDNi4OnIpg2", "Avril 14th (Aphex Twin) - Vanessa Wagner Version", ["Murcof", "Vanessa Wagner"], 165020, 0.119, 0.083),
        ("2o2NJlqxbMoPmRAatR4MeL", "Bamse och Bronto - Del.1", ["Bamse"], 193250, 0.552, 0.381),
        ("7Km4W3atUNjhf05szq2Gkb", "Diary", ["Bread"], 189426, 0.430, 0.126),
        ("5D0r1uBb8jOBH4djqq6weE", "gloaming atmospheres", ["Harry G's Beats"], 149166, 0.051, 0.076),
        ("6UHpig2j4FFQPQA6jY1OnW", "Por Que Te Alejas de Dios", ["Marino", "Stanislao Marino"], 271415, 0.631, 0.243),
        ("3ytMGJUOv7KvVpOSAow62b", "The Legend of Ashitaka - from 'Princess Mononoke'", ["Joe Hisaishi", "Royal Philharmonic Orchestra"], 117920, 0.167, 0.208),
        ("2e8MxBgVWMSQmxb2zcuCoq", "Die Walkure, Act III: Ride of the Valkyries", ["Budapest Symphony Orchestra", "Richard Wagner", "György Lehel"], 325000, 0.097, 0.219),
        ("4nwSwALkSaxA26bEANsi20", "Eve", ["Avenoir"], 163728, 0.254, 0.117),
        ("6g63N2FQjWnQWFK7hSXK6e", "Lighten Up Dreams", ["Diminished Fusion"], 236415, 0.234, 0.129),
        ("4dUVpbIu8FW7R76gejw3cq", "Quintessence", ["Coleman Hawkins Quartet", "Coleman Hawkins", "Quincy Jones"], 284680, 0.127, 0.129),
        ("4NpX4g7sdnZtgteu1m2m3S", "Forces of Attraction", ["Jóhann Jóhannsson"], 123157, 0.403, 0.126),
        ("6yOvurgteDmqpcJ3nV5tFi", "Verde", ["Canciones Infantiles Bebe TaTaTa", "Las Ruedas Del Autobús", "Martinillo"], 75109, 0.246, 0.155),
        ("7FioFdMkEjmaExBR4NjIVo", "Kapitel 02 - Die Weihnachtsmänner (Folge 038)", ["Bibi Blocksberg"], 95157, 0.621, 0.356),
        ("1gNcPHAiVIQZmqJFJdt3ti", "Dry Hands", ["C418"], 68500, 0.342, 0.007),
    ]

    static func songs(_ rows: [Row]) -> [MixSong] {
        rows.map { MixSong(id: $0.id, title: $0.title, artists: $0.artists, durationMs: $0.durationMs) }
    }

    static func features(_ rows: [Row]) -> [String: MixFeatures] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.id, MixFeatures(valence: $0.valence, energy: $0.energy)) })
    }
}
