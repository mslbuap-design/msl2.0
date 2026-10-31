import { useEffect, useMemo, useRef, useState } from 'react';
import { AlertTriangle } from 'lucide-react';
import Button from '../../components/ui/Button.jsx';
import { BotonExportar, MarcaFase } from './ElementosGrafos.jsx';
import GraficoGrupos from './GraficoGrupos.jsx';
import {
  ALFA_POR_DEFECTO,
  avisoResolucion,
  construirPeticion,
  filasVisibles,
  fmtNum,
  formatearConIC,
  formatearMediana,
  formatearP,
  formatearPrueba,
  gruposDisponibles,
  infoCaracteristica,
  magnitudCliff,
  ordenarConReferencia,
  puntosPorGrupo,
  textoEstado,
  textoOrientacion,
  validarSeleccion,
} from './comparacionUtils.js';

/**
 * Comparación de grupos (Fase 3B), dentro de la pestaña Grafos: un valor por sujeto y característica, prueba principal
 * (no paramétrica por defecto), tamaños de efecto y corrección por comparaciones múltiples. Las definiciones están en
 * docs/CAMBIOS_PARA_GRAFOS.md; acá solo hay etiquetas cortas.
 */
export default function ComparacionGrupos({ sujetos, comparacion, comparando, onComparar, onExportarCsv, onExportarExcel, exportando }) {
  const disponibles = useMemo(() => gruposDisponibles(sujetos), [sujetos]);
  const firmaGrupos = disponibles.map((d) => `${d.nombre}:${d.n}`).join('|');

  // Al inicio: todos los grupos comparables elegidos y el primero como referencia.
  const iniciales = disponibles.filter((d) => d.comparable).map((d) => d.nombre);
  const [seleccion, setSeleccion] = useState(iniciales);
  const [referencia, setReferencia] = useState(iniciales[0] || '');
  const [pruebaPrincipal, setPruebaPrincipal] = useState('no_parametrica');
  const [alfaTexto, setAlfaTexto] = useState(ALFA_POR_DEFECTO);
  const [soloSignificativas, setSoloSignificativas] = useState(false);
  const [claveActiva, setClaveActiva] = useState(null);

  // Resultados nuevos (otro análisis): se vuelve a la selección inicial. En el primer dibujo ya está puesta.
  const firmaPrevia = useRef(firmaGrupos);
  useEffect(() => {
    if (firmaPrevia.current === firmaGrupos) return;
    firmaPrevia.current = firmaGrupos;
    setSeleccion(iniciales);
    setReferencia(iniciales[0] || '');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [firmaGrupos]);

  // Comparación nueva: se vuelve a la primera fila.
  useEffect(() => setClaveActiva(null), [comparacion]);

  const gruposOrdenados = useMemo(() => ordenarConReferencia(seleccion, referencia), [seleccion, referencia]);
  const erroresSeleccion = useMemo(() => validarSeleccion(gruposOrdenados, disponibles, sujetos), [gruposOrdenados, disponibles, sujetos]);
  const { peticion, errores: erroresPeticion } = useMemo(
    () => construirPeticion({ sujetos, grupos: gruposOrdenados, pruebaPrincipal, alfaTexto }),
    [sujetos, gruposOrdenados, pruebaPrincipal, alfaTexto],
  );
  const errores = [...erroresSeleccion, ...erroresPeticion];
  const aviso = useMemo(() => avisoResolucion(sujetos, gruposOrdenados), [sujetos, gruposOrdenados]);

  const alternarGrupo = (nombre) => {
    const orden = disponibles.map((d) => d.nombre);
    const nueva = seleccion.includes(nombre) ? seleccion.filter((g) => g !== nombre) : orden.filter((n) => n === nombre || seleccion.includes(n));
    setSeleccion(nueva);
    if (!nueva.includes(referencia)) setReferencia(nueva[0] || '');
  };

  const comparables = disponibles.filter((d) => d.comparable);
  if (comparables.length < 2) {
    return (
      <div className="flex-1 min-h-0 flex flex-col items-center justify-center text-center px-6">
        <p className="text-ink text-base font-medium mb-1">Hacen falta al menos 2 grupos con 2 sujetos cada uno</p>
        <p className="text-muted text-sm max-w-md">
          Los grupos son las carpetas del proyecto (Proyecto/Grupo/archivo). Ahora hay:{' '}
          {disponibles.length > 0 ? disponibles.map((d) => `${d.nombre} (${d.n})`).join(', ') : 'ningún resultado con características'}.
        </p>
      </div>
    );
  }

  const resumen = comparacion?.resumen;
  const gruposResultado = resumen?.grupos || [];
  const filas = filasVisibles(comparacion?.resultados, soloSignificativas);
  const filaActiva = (comparacion?.resultados || []).find((f) => f.clave === claveActiva) || filas[0] || null;
  const dosGrupos = gruposResultado.length === 2;

  return (
    <div className="flex-1 min-h-0 overflow-y-auto pr-1 space-y-4">
      {/* Selección y opciones */}
      <section className="bg-bg rounded-lg border border-line p-4 space-y-4" aria-label="Opciones de la comparación">
        <div className="flex items-center justify-between gap-2">
          <h3 className="text-base font-semibold text-ink">Comparación de grupos</h3>
          <MarcaFase texto="Fase 3B" />
        </div>

        <fieldset className="space-y-1.5">
          <legend className="text-xs font-medium text-muted mb-1">Grupos</legend>
          {disponibles.map((d) => (
            <div key={d.nombre} className="flex items-center gap-4 text-sm">
              <label className="flex items-center gap-2 flex-1 min-w-0 cursor-pointer">
                <input
                  type="checkbox"
                  checked={seleccion.includes(d.nombre)}
                  disabled={!d.comparable}
                  onChange={() => alternarGrupo(d.nombre)}
                  className="w-4 h-4 accent-accent"
                />
                <span className="truncate text-ink">{d.nombre}</span>
                <span className="text-xs text-muted font-data">n = {d.n}</span>
                {!d.comparable && <span className="text-xs text-faint">necesita 2 o más</span>}
              </label>
              <label className="flex items-center gap-1.5 text-xs text-muted cursor-pointer">
                <input
                  type="radio"
                  name="grupo-referencia"
                  checked={referencia === d.nombre}
                  disabled={!seleccion.includes(d.nombre)}
                  onChange={() => setReferencia(d.nombre)}
                  className="accent-accent"
                />
                Referencia
              </label>
            </div>
          ))}
        </fieldset>

        <div className="flex flex-wrap items-end gap-x-6 gap-y-3">
          <fieldset>
            <legend className="text-xs font-medium text-muted mb-1">Prueba principal</legend>
            <div className="flex flex-wrap gap-x-4 gap-y-1 text-sm text-ink">
              <label className="flex items-center gap-1.5 cursor-pointer">
                <input type="radio" name="prueba-principal" checked={pruebaPrincipal === 'no_parametrica'} onChange={() => setPruebaPrincipal('no_parametrica')} className="accent-accent" />
                No paramétrica (Mann–Whitney / Kruskal–Wallis)
              </label>
              <label className="flex items-center gap-1.5 cursor-pointer">
                <input type="radio" name="prueba-principal" checked={pruebaPrincipal === 'parametrica'} onChange={() => setPruebaPrincipal('parametrica')} className="accent-accent" />
                Paramétrica (Welch)
              </label>
            </div>
          </fieldset>

          <label className="text-xs font-medium text-muted">
            <span className="block mb-1">Nivel α</span>
            <input
              type="text"
              inputMode="decimal"
              value={alfaTexto}
              onChange={(e) => setAlfaTexto(e.target.value)}
              aria-invalid={erroresPeticion.length > 0}
              className="w-20 px-2 py-1.5 text-sm text-ink font-data border border-line rounded bg-surface focus:outline-none focus:ring-2 focus:ring-accent/40"
            />
          </label>

          <Button onClick={() => onComparar(peticion)} disabled={comparando || errores.length > 0}>
            {comparando ? 'Comparando…' : 'Comparar grupos'}
          </Button>
        </div>
        <p className="text-xs text-faint">Se calculan las dos pruebas; la principal es la que se corrige por comparaciones múltiples (Benjamini–Hochberg).</p>

        {errores.length > 0 && (
          <ul className="text-xs text-danger space-y-0.5" role="alert">
            {errores.map((e) => (
              <li key={e}>{e}</li>
            ))}
          </ul>
        )}
      </section>

      {aviso.hay && (
        <div className="flex items-start gap-2 p-3 rounded-lg border border-warning/30 bg-warning-50 text-sm text-warning" role="status">
          <AlertTriangle size={16} className="mt-0.5 flex-shrink-0" />
          <p>
            La resolución del vóxel difiere entre los grupos elegidos ({aviso.detalle.map((d) => `eje ${d.eje}: ×${d.razon.toFixed(2)}`).join(', ')}). Puede
            producir diferencias que no son anatómicas.
          </p>
        </div>
      )}

      {comparacion && resumen && (
        <>
          <section className="space-y-3" aria-label="Resultados de la comparación">
            <div className="flex items-center justify-between gap-3 flex-wrap">
              <p className="text-sm text-ink">
                <span className="font-medium font-data">{resumen.n_significativas}</span> de <span className="font-data">{resumen.m}</span> características
                significativas <span className="text-muted">(q de Benjamini–Hochberg ≤ {resumen.alfa}; referencia: {resumen.referencia}; n = {gruposResultado.map((g) => `${resumen.n_sujetos?.[g] ?? '-'}`).join(' / ')})</span>
              </p>
              <div className="flex items-center gap-1.5 flex-wrap">
                <span className="text-xs text-muted">{exportando ? 'Exportando…' : 'Exportar:'}</span>
                <BotonExportar onClick={() => onExportarCsv('comparacion')} disabled={exportando} titulo="Una fila por característica: descriptivos, pruebas, efectos, p, q y Holm">
                  CSV comparación
                </BotonExportar>
                {!dosGrupos && (
                  <BotonExportar onClick={() => onExportarCsv('pares')} disabled={exportando} titulo="Mann–Whitney por pares con Holm, una fila por característica y par">
                    CSV pares
                  </BotonExportar>
                )}
                <BotonExportar onClick={onExportarExcel} disabled={exportando} titulo="Excel con Sujetos, Aristas, Nodos, Comparación (y Pares) y Leeme">
                  Excel con comparación
                </BotonExportar>
              </div>
            </div>
            <p className="text-xs text-muted">{textoOrientacion(gruposResultado)}</p>
            <label className="flex items-center gap-2 text-sm text-ink cursor-pointer w-fit">
              <input type="checkbox" checked={soloSignificativas} onChange={(e) => setSoloSignificativas(e.target.checked)} className="w-4 h-4 accent-accent" />
              Solo significativas
            </label>

            <div className="overflow-x-auto bg-surface rounded-lg border border-line">
              <table className="min-w-full divide-y divide-line text-sm">
                <thead className="bg-bg">
                  <tr>
                    <Th>Característica</Th>
                    <Th>n</Th>
                    {gruposResultado.map((g) => (
                      <Th key={g} sub="mediana (p25–p75)">
                        {g}
                      </Th>
                    ))}
                    {dosGrupos ? (
                      <>
                        <Th sub="IC 95 %" titulo="Probabilidad de que un sujeto del grupo comparado supere a uno de la referencia (0,5 = nada)">
                          AUC
                        </Th>
                        <Th sub="IC 95 %" titulo="δ de Cliff = 2·AUC − 1, entre −1 y 1">
                          δ de Cliff
                        </Th>
                      </>
                    ) : (
                      <Th titulo="ε² de Kruskal–Wallis = H / (N − 1)">ε²</Th>
                    )}
                    <Th right>p</Th>
                    <Th right titulo="Benjamini–Hochberg sobre las características con p válido">q</Th>
                    <Th>Significativa</Th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-line">
                  {filas.length === 0 && (
                    <tr>
                      <td colSpan={(dosGrupos ? 7 : 6) + gruposResultado.length} className="px-4 py-6 text-center text-sm text-muted">
                        Ninguna característica es significativa con este α.
                      </td>
                    </tr>
                  )}
                  {filas.map((f) => (
                    <FilaTabla
                      key={f.clave}
                      fila={f}
                      grupos={gruposResultado}
                      dosGrupos={dosGrupos}
                      activa={filaActiva?.clave === f.clave}
                      onElegir={() => setClaveActiva(f.clave)}
                    />
                  ))}
                </tbody>
              </table>
            </div>
          </section>

          {filaActiva && <DetalleCaracteristica fila={filaActiva} grupos={gruposResultado} sujetos={sujetos} />}
        </>
      )}
    </div>
  );
}

function Th({ children, sub, right = false, titulo }) {
  return (
    <th scope="col" title={titulo} className={`px-3 py-2.5 text-xs font-medium text-muted ${right ? 'text-right' : 'text-left'} align-bottom`}>
      <span className="block text-ink">{children}</span>
      {sub && <span className="block font-normal text-faint">{sub}</span>}
    </th>
  );
}

function FilaTabla({ fila, grupos, dosGrupos, activa, onElegir }) {
  const info = infoCaracteristica(fila.clave);
  const ef = fila.efecto || {};
  const conP = fila.estado === 'ok';
  const estado = textoEstado(fila);
  return (
    <tr className={activa ? 'bg-accent-50' : 'hover:bg-bg'}>
      <td className="px-3 py-2 min-w-[11rem]">
        <button
          type="button"
          onClick={onElegir}
          aria-pressed={activa}
          title={info.ayuda || info.clave}
          className="text-left text-ink font-medium hover:text-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-accent/40 rounded"
        >
          {info.etiqueta}
        </button>
        <span className="block text-xs text-faint">{info.grupo || fila.clave}</span>
      </td>
      <td className="px-3 py-2 text-muted font-data whitespace-nowrap">{grupos.map((g) => fila.n?.[g] ?? '-').join(' / ')}</td>
      {grupos.map((g) => (
        <td key={g} className="px-3 py-2 text-ink font-data whitespace-nowrap">
          {formatearMediana(fila.descriptivos?.[g], info.dec)}
        </td>
      ))}
      {dosGrupos ? (
        <>
          <td className="px-3 py-2 text-ink font-data whitespace-nowrap">{formatearConIC(ef.auc, ef.auc_ic, 2)}</td>
          <td className="px-3 py-2 text-ink font-data whitespace-nowrap">
            {formatearConIC(ef.cliff_delta, ef.cliff_ic, 2)}
            {magnitudCliff(ef.cliff_delta) && <span className="ml-1 font-sans text-xs text-muted">{magnitudCliff(ef.cliff_delta)}</span>}
          </td>
        </>
      ) : (
        <td className="px-3 py-2 text-ink font-data">{fmtNum(ef.epsilon2, 2)}</td>
      )}
      <td className="px-3 py-2 text-right text-ink font-data">{conP ? formatearP(fila.p) : <span className="font-sans text-xs text-muted">{estado}</span>}</td>
      <td className="px-3 py-2 text-right text-ink font-data">{conP ? formatearP(fila.q_bh) : '—'}</td>
      <td className="px-3 py-2">
        {fila.significativa ? <span className="inline-block px-2 py-0.5 text-xs font-medium rounded-full bg-success-50 text-success">Sí</span> : <span className="text-faint">—</span>}
      </td>
    </tr>
  );
}

function DetalleCaracteristica({ fila, grupos, sujetos }) {
  const info = infoCaracteristica(fila.clave);
  const ef = fila.efecto || {};
  const dosGrupos = grupos.length === 2;
  const puntos = useMemo(() => puntosPorGrupo(sujetos, fila.clave, grupos), [sujetos, fila.clave, grupos]);
  const hayPruebas = fila.estado === 'ok' || fila.estado === 'no_estimable';

  return (
    <section className="bg-bg rounded-lg border border-line p-4 space-y-4" aria-label={`Detalle de ${info.etiqueta}`}>
      <div>
        <h4 className="text-sm font-semibold text-ink">
          {info.grupo ? `${info.grupo}: ` : ''}
          {info.etiqueta}
        </h4>
        <p className="text-xs text-faint font-data">{fila.clave}</p>
        {info.ayuda && <p className="text-xs text-muted mt-1">{info.ayuda}</p>}
      </div>

      <div className="flex flex-wrap gap-6 items-start">
        <div className="flex-1 min-w-[18rem]">
          <GraficoGrupos puntos={puntos} grupos={grupos} dec={info.dec} etiqueta={info.etiqueta} />
        </div>

        <dl className="flex-1 min-w-[18rem] text-sm grid grid-cols-[auto_1fr] gap-x-4 gap-y-2">
          {hayPruebas && (
            <>
              <dt className="text-muted">Prueba principal</dt>
              <dd className="text-ink font-data">{formatearPrueba(fila.prueba_principal)}</dd>
              <dt className="text-muted">Otra prueba</dt>
              <dd className="text-ink font-data">{formatearPrueba(fila.otra_prueba)}</dd>
            </>
          )}
          {fila.estado === 'ok' && (
            <>
              <dt className="text-muted">Corrección</dt>
              <dd className="text-ink font-data">
                p = {formatearP(fila.p)}, q (BH) = {formatearP(fila.q_bh)}, p (Holm) = {formatearP(fila.p_holm)}
              </dd>
            </>
          )}
          {fila.estado === 'ok' && dosGrupos && (
            <>
              <dt className="text-muted">AUC</dt>
              <dd className="text-ink font-data">{formatearConIC(ef.auc, ef.auc_ic, 2)}</dd>
              <dt className="text-muted">δ de Cliff</dt>
              <dd className="text-ink font-data">
                {formatearConIC(ef.cliff_delta, ef.cliff_ic, 2)}
                {magnitudCliff(ef.cliff_delta) && <span className="ml-1 font-sans text-xs text-muted">({magnitudCliff(ef.cliff_delta)})</span>}
              </dd>
              <dt className="text-muted">g de Hedges</dt>
              <dd className="text-ink font-data">{formatearConIC(ef.hedges_g, ef.hedges_ic, 2)}</dd>
              <dt className="text-muted">Menor p posible</dt>
              <dd className="text-ink font-data">{formatearP(fila.p_min_posible)}</dd>
            </>
          )}
          {fila.estado === 'ok' && !dosGrupos && (
            <>
              <dt className="text-muted">ε² (Kruskal–Wallis)</dt>
              <dd className="text-ink font-data">{fmtNum(ef.epsilon2, 3)}</dd>
              <dt className="text-muted">η²</dt>
              <dd className="text-ink font-data">{fmtNum(ef.eta2, 3)}</dd>
            </>
          )}
          {fila.mayor_en && (
            <>
              <dt className="text-muted">Mayor rango en</dt>
              <dd className="text-ink">{fila.mayor_en}</dd>
            </>
          )}
          {fila.nota && (
            <>
              <dt className="text-muted">Nota</dt>
              <dd className="text-ink">{fila.nota}</dd>
            </>
          )}
        </dl>
      </div>

      <div className="overflow-x-auto">
        <table className="text-xs border border-line rounded bg-surface">
          <thead className="bg-bg text-muted">
            <tr>
              {['Grupo', 'n', 'Mediana', 'p25', 'p75', 'Media', 'Desv. estándar'].map((h, i) => (
                <th key={h} scope="col" className={`px-3 py-1 font-medium ${i === 0 ? 'text-left' : 'text-right'}`}>
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="font-data">
            {grupos.map((g) => {
              const d = fila.descriptivos?.[g] || {};
              return (
                <tr key={g} className="border-t border-line">
                  <td className="px-3 py-1 font-sans text-ink">{g}</td>
                  <td className="px-3 py-1 text-right">{d.n ?? '-'}</td>
                  <td className="px-3 py-1 text-right">{fmtNum(d.mediana, info.dec + 1)}</td>
                  <td className="px-3 py-1 text-right">{fmtNum(d.p25, info.dec + 1)}</td>
                  <td className="px-3 py-1 text-right">{fmtNum(d.p75, info.dec + 1)}</td>
                  <td className="px-3 py-1 text-right">{fmtNum(d.media, info.dec + 1)}</td>
                  <td className="px-3 py-1 text-right">{fmtNum(d.sd, info.dec + 1)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {!dosGrupos && Array.isArray(fila.pares) && fila.pares.length > 0 && (
        <div className="overflow-x-auto">
          <p className="text-xs font-medium text-muted mb-1">Comparaciones por pares (Mann–Whitney, p ajustado por Holm dentro de la característica)</p>
          <table className="text-xs border border-line rounded bg-surface">
            <thead className="bg-bg text-muted">
              <tr>
                {['Par (segundo frente a primero)', 'U', 'p', 'p (Holm)', 'AUC', 'δ de Cliff', 'Mayor en'].map((h, i) => (
                  <th key={h} scope="col" className={`px-3 py-1 font-medium ${i === 0 || i === 6 ? 'text-left' : 'text-right'}`}>
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="font-data">
              {fila.pares.map((p) => (
                <tr key={`${p.a}|${p.b}`} className="border-t border-line">
                  <td className="px-3 py-1 font-sans text-ink">
                    {p.b} frente a {p.a}
                  </td>
                  <td className="px-3 py-1 text-right">{fmtNum(p.u, 1)}</td>
                  <td className="px-3 py-1 text-right">{formatearP(p.p)}</td>
                  <td className="px-3 py-1 text-right">{formatearP(p.p_holm)}</td>
                  <td className="px-3 py-1 text-right">{formatearConIC(p.auc, p.auc_ic, 2)}</td>
                  <td className="px-3 py-1 text-right">{formatearConIC(p.cliff_delta, p.cliff_ic, 2)}</td>
                  <td className="px-3 py-1 font-sans">{p.mayor_en || '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
