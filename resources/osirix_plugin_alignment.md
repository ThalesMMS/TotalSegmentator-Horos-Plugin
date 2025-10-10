# Horos/OsiriX TotalSegmentator Plugin Alignment

## 1. Levantamento do plugin existente

### 1.1 Fontes auditadas
- Repositório atual do TotalSegmentator: nenhuma pasta ou arquivo relacionado a um plugin Horos/OsiriX foi localizada (`rg "OsiriX"` e `rg "Horos"` retornaram vazios).
- Documentação pública do projeto: não descreve um plugin OsiriX específico.

> **Ação pendente:** solicitar à equipe responsável o código-fonte, binários ou documentação interna do plugin para que o layout e os fluxos possam ser extraídos com precisão.

### 1.2 Controles visíveis
Sem acesso ao plugin não foi possível inventariar os controles reais. Abaixo está uma lista base inicial a ser validada assim que o material estiver disponível:

| Tela | Controle | Tipo | Status |
| --- | --- | --- | --- |
| Tela principal | Seleção de modelo (`Task`) | Combo box | Necessita confirmação (suporte aos modelos definidos na Seção 3) |
| Tela principal | "Processar em GPU" | Toggle/checkbox | Necessita confirmação |
| Tela principal | "Modo rápido" | Toggle/checkbox | Necessita confirmação |
| Tela principal | "Modo ultrarrápido" | Toggle/checkbox | Necessita confirmação |
| Tela principal | "Número de licença" | Campo de texto | Necessita confirmação |
| Tela principal | "Dispositivo" (CPU / GPU específica) | Combo box | Necessita confirmação |
| Tela principal | "Não importar ROIs" | Toggle/checkbox | Necessita confirmação |
| Tela principal | "Pré-visualizar" | Toggle/checkbox | Necessita confirmação |
| Tela de resultados | Lista de estruturas segmentadas | Lista | Necessita confirmação |

> **Próximo passo:** Assim que o plugin for disponibilizado, substituir esta tabela pela listagem completa e fiel aos controles visíveis (incluindo nomes, estados padrão e qualquer validação de input).

## 2. Mapeamento de controles para parâmetros `TotalSegmentator`

| Controle na interface | Parâmetro CLI | Valores/Notas |
| --- | --- | --- |
| Seleção de modelo (`Task`) | `--task` | Popular com a lista validada na Seção 3. | 
| "Modo rápido" | `--fast` | Habilitar quando o toggle estiver ativado (desabilitar `--fastest`). |
| "Modo ultrarrápido" | `--fastest` | Habilitar quando o toggle estiver ativado (implica `--fast`). |
| "Processar em GPU" | `--device` | `gpu` quando marcado; `cpu` quando desmarcado. Oferecer campo avançado para `gpu:X` se múltiplas GPUs estiverem disponíveis. |
| Seleção manual de dispositivo | `--device` | Campo avançado permitindo `cpu`, `gpu`, `gpu:X`. |
| "Número de licença" | `--license_number` | Enviar somente quando preenchido. |
| "Pré-visualizar" | `--preview` | Opcional, gera `preview.png`. |
| "Gerar estatísticas" | `--statistics` | Se necessário pela clínica. |
| "Exportar radiomics" | `--radiomics` | Requer dependência extra (`pyradiomics`). |
| "Salvar em arquivo único" | `--ml` | Gera um único volume rotulado. |
| "Importar apenas estruturas selecionadas" | `--roi_subset` | Recebe lista de estruturas selecionadas. |
| "Corte robusto" | `--robust_crop` | Ativar conforme preferências de desempenho x robustez. |
| "Não importar ROIs" | Sem parâmetro direto | Ver Seção 4 (comportamento implementado no pós-processamento de resultados). |

Referência dos parâmetros disponível na documentação oficial.【F:README.md†L94-L157】【F:README.md†L164-L205】

## 3. Modelos (`--task`) e rótulos padrão

### 3.1 Proposta inicial para validação clínica
A partir dos modelos públicos suportados pelo TotalSegmentator, sugerimos disponibilizar por padrão:

| Identificador CLI | Rótulo sugerido no Horos | Justificativa |
| --- | --- | --- |
| `total` | "Total (CT)" | Cobertura completa para TC; opção mais utilizada.【F:README.md†L61-L88】 |
| `total_mr` | "Total (MR)" | Equivalente para ressonância magnética.【F:README.md†L61-L88】 |
| `lung_vessels` | "Vasos Pulmonares" | Segmentação específica de vasos pulmonares.【F:README.md†L94-L157】 |
| `body` | "Corpo (CT)" | Foco no contorno corporal em TC.【F:README.md†L94-L157】 |
| `vertebrae_mr` | "Vértebras (MR)" | Interesse frequente em ortopedia/coluna para RM.【F:README.md†L94-L157】 |
| `liver_vessels` | "Vasos Hepáticos" | Uso em planejamento hepático.【F:README.md†L110-L133】 |

> **Ação:** Validar com a equipe clínica se esses modelos cobrem os fluxos prioritários, ajustar a lista e os rótulos conforme vocabulário adotado no Horos.

### 3.2 Modelos licenciados
Caso a instituição possua licença, incluir as opções adicionais (ex.: `heartchambers_highres`, `tissue_types`). Rótulos devem indicar claramente a necessidade de licença. 【F:README.md†L206-L244】

## 4. Comportamento de toggles adicionais e backend

| Toggle | Comportamento esperado | Implementação backend |
| --- | --- | --- |
| "Não importar ROIs" | Ignorar a criação de ROIs no Horos após a segmentação. | Após a execução do `TotalSegmentator`, interceptar o fluxo de importação: apagar/ignorar arquivos de label antes de criar ROIs ou encapsular o resultado em uma camada alternativa (ex.: gerar apenas `statistics.json`). |
| "Salvar resultado único" | Agrupar classes em um volume único. | Passar `--ml` e adaptar a rotina de importação para lidar com um arquivo rotulado multi-label. |
| "Pré-visualizar" | Exibir `preview.png` no Horos sem criar ROIs. | Executar com `--preview` e, após a saída, anexar a prévia ao estudo (como série secundária). |
| "Importar apenas classes selecionadas" | Usuário marca quais classes quer importar como ROI. | Preencher `--roi_subset` com a lista de classes; após execução, importar somente os arquivos correspondentes. |
| "Forçar CPU" | Garantir execução sem GPU. | Definir `--device cpu` independentemente da detecção automática. |
| "Selecionar GPU específica" | Escolher GPU `cuda:N`. | Interface deve aceitar string `gpu:N`; backend repassa diretamente ao parâmetro `--device`. |

> **Nota:** Toggles que não correspondam diretamente a parâmetros CLI devem ser implementados em camadas adicionais (pré-processamento ou pós-processamento). Ex.: "Não importar ROIs" age após a geração dos arquivos.

## 5. Próximos passos
1. Obter o material do plugin existente para substituir as suposições do inventário (Seção 1.2).
2. Validar com a equipe clínica a lista de modelos e rótulos (Seção 3.1).
3. Confirmar requisitos regulatórios associados ao campo `--license_number`.
4. Definir estratégia de atualização de pesos (`totalseg_download_weights`) e cache local.
5. Documentar o fluxo de exceções/erros (ex.: falta de GPU, licença inválida) em versão futura deste documento.
